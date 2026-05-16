// WebSocket echo server (Node.js, `ws` package, ESM).
// Binds explicitly to SERVER_IP inside ns_server — never localhost.

import { WebSocketServer } from 'ws';

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

const wss = new WebSocketServer({ host, port });

wss.on('listening', () => {
    console.log(`ws echo listening on ${host}:${port}`);
});

wss.on('connection', (ws, req) => {
    const peer = `${req.socket.remoteAddress}:${req.socket.remotePort}`;
    console.log(`conn open ${peer}`);

    ws.on('message', (data, isBinary) => {
        // Strict echo: bounce the exact payload back to this client only.
        ws.send(data, { binary: isBinary });
    });

    ws.on('close', () => console.log(`conn close ${peer}`));
    ws.on('error', (err) => console.error(`conn error ${peer}:`, err.message));
});

wss.on('error', (err) => {
    console.error('server error:', err);
    process.exit(1);
});

for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
        console.log(`received ${sig}, closing`);
        wss.close(() => process.exit(0));
    });
}
