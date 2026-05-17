// WebTransport echo server (Deno, @fails-components/webtransport via npm: specifier).
// Uses Deno's Node.js compatibility layer to run the libquiche N-API backend.
// Does NOT require --unstable-net (libquiche handles QUIC directly, not Deno.QuicEndpoint).
//
// Accepts bidirectional streams and echoes every chunk back immediately.

import { readFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
// Importing the transport package triggers the native binary load.
import 'npm:@fails-components/webtransport-transport-http3-quiche';
import { quicheLoaded, Http3Server } from 'npm:@fails-components/webtransport';

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

await quicheLoaded;

const dir = dirname(fileURLToPath(import.meta.url));
const cert = readFileSync(`${dir}/../cert.pem`, 'utf8');
const privKey = readFileSync(`${dir}/../key.pem`, 'utf8');

const server = new Http3Server({ port, host, secret: 'benchmark', cert, privKey });
server.startServer();
await server.ready;
console.log(`webtransport echo listening on ${host}:${port}`);

async function handleStream(stream: { readable: ReadableStream; writable: WritableStream }): Promise<void> {
    try {
        await stream.readable.pipeTo(stream.writable);
    } catch {
        // Client closed the stream — normal on benchmark end.
    }
}

async function handleSession(session: any): Promise<void> {
    console.log('conn open');
    try {
        const reader = session.incomingBidirectionalStreams.getReader();
        while (true) {
            const { value: stream, done } = await reader.read();
            if (done) break;
            handleStream(stream);
        }
    } catch {
        // Session closed.
    }
    console.log('conn close');
}

const sessionReader = (server.sessionStream('/') as ReadableStream).getReader();
(async () => {
    while (true) {
        const { value: session, done } = await sessionReader.read();
        if (done) break;
        handleSession(session);
    }
})();
