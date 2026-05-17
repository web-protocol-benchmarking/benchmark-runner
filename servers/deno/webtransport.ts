// WebTransport echo server (Deno, native QUIC via Deno.QuicEndpoint).
// Requires --unstable-net flag.
//
// Accepts bidirectional streams from each client and echoes every chunk back
// immediately. A single bidi stream is held open for the full benchmark run —
// the client drives closed-loop depth=1 writes/reads over it.

const host = Deno.env.get('SERVER_IP');
const portStr = Deno.env.get('SERVER_PORT');
const port = Number(portStr);

if (!host) {
    console.error('SERVER_IP env var is required (set by run_test.sh).');
    Deno.exit(1);
}
if (!Number.isInteger(port) || port <= 0) {
    console.error('SERVER_PORT env var must be a positive integer.');
    Deno.exit(1);
}

const certDir = new URL('../', import.meta.url);
const cert = await Deno.readTextFile(new URL('cert.pem', certDir));
const key = await Deno.readTextFile(new URL('key.pem', certDir));

const endpoint = new Deno.QuicEndpoint({ hostname: host, port });
const listener = endpoint.listen({ cert, key, alpnProtocols: ['h3'] });

console.log(`webtransport echo listening on ${host}:${port}`);

async function handleStream(
    stream: { readable: ReadableStream<Uint8Array>; writable: WritableStream<Uint8Array> },
): Promise<void> {
    const reader = stream.readable.getReader();
    const writer = stream.writable.getWriter();
    try {
        while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            await writer.write(value);
        }
    } catch {
        // Client closed the stream or connection — normal shutdown.
    } finally {
        reader.releaseLock();
        writer.releaseLock();
    }
}

async function handleConnection(conn: Deno.QuicConn): Promise<void> {
    const peer = `${conn.remoteAddr.hostname}:${conn.remoteAddr.port}`;
    let wt: WebTransport;
    try {
        wt = await Deno.upgradeWebTransport(conn);
        await wt.ready;
    } catch (err) {
        console.error(`upgrade failed ${peer}:`, err);
        return;
    }
    console.log(`conn open ${peer}`);

    const streamPromises: Promise<void>[] = [];
    const reader = wt.incomingBidirectionalStreams.getReader();
    try {
        while (true) {
            const { value: stream, done } = await reader.read();
            if (done) break;
            streamPromises.push(handleStream(stream));
        }
    } catch {
        // Connection closed.
    } finally {
        reader.releaseLock();
    }

    await Promise.allSettled(streamPromises);
    console.log(`conn close ${peer}`);
}

// listener.accept() resolves the QUIC handshake and returns a QuicConn.
// Loop manually rather than using `for await` over the listener, because the
// async iterator yields QuicIncoming (a thenable that resolves to itself, not
// to a QuicConn). listener.accept() is the correct call to get a QuicConn.
while (true) {
    let conn: Deno.QuicConn;
    try {
        conn = await listener.accept();
    } catch {
        break; // Listener closed.
    }
    // Fire-and-forget per connection so the accept loop keeps running.
    handleConnection(conn);
}
