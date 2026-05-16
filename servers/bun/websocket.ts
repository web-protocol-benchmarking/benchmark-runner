// WebSocket echo server (Bun, native Bun.serve).
// Binds explicitly to SERVER_IP inside ns_server — never localhost.

const host = process.env.SERVER_IP;
const port = Number(process.env.SERVER_PORT);

if (!host) {
    console.error('SERVER_IP env var is required (set by run_test.sh).');
    process.exit(1);
}
if (!Number.isInteger(port) || port <= 0) {
    console.error('SERVER_PORT env var must be a positive integer.');
    process.exit(1);
}

Bun.serve({
    hostname: host,
    port,
    fetch(req, server) {
        if (server.upgrade(req)) return; // upgraded — handled by websocket{}
        return new Response('expected websocket upgrade', { status: 426 });
    },
    websocket: {
        open(ws) {
            console.log(`conn open ${ws.remoteAddress}`);
        },
        message(ws, message) {
            // Strict echo: bounce the exact payload back to this client only.
            ws.send(message);
        },
        close(ws) {
            console.log(`conn close ${ws.remoteAddress}`);
        },
    },
});

console.log(`ws echo listening on ${host}:${port}`);
