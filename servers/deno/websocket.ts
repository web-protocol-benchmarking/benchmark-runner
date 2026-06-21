// WebSocket echo server (Deno, native Deno.serve).
// Binds explicitly to SERVER_IP inside ns_server — never localhost.

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

// TLS (wss://) for a fair comparison vs WebTransport; same cert idiom as webtransport.ts.
const certDir = new URL('../', import.meta.url);
const cert = await Deno.readTextFile(new URL('cert.pem', certDir));
const key = await Deno.readTextFile(new URL('key.pem', certDir));

Deno.serve({ hostname: host, port, cert, key }, (req) => {
    if (req.headers.get('upgrade')?.toLowerCase() !== 'websocket') {
        return new Response('expected websocket upgrade', { status: 426 });
    }

    // Read request headers BEFORE upgrading: as of Deno 2.8, upgradeWebSocket()
    // consumes the request, so touching req.headers afterwards throws
    // "Request closed" and the upgrade response is never returned.
    const peer = req.headers.get('x-forwarded-for') ?? 'peer';
    const { socket, response } = Deno.upgradeWebSocket(req);

    socket.onopen = () => console.log(`conn open ${peer}`);
    socket.onmessage = (ev) => {
        // Strict echo: bounce the exact payload back to this client only.
        socket.send(ev.data);
    };
    socket.onclose = () => console.log(`conn close ${peer}`);
    socket.onerror = (err) => console.error(`conn error ${peer}:`, err);

    return response;
});

console.log(`ws echo listening on ${host}:${port}`);
