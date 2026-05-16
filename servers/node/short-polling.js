// Long-polling echo server (Node.js, ESM).
//
// Single endpoint: POST /echo
//   Body: 30-byte JSON payload from the client.
//   Response: the exact same bytes, Content-Type application/json.
//
// Each request opens a fresh TCP/HTTP cycle on the client side — that cost
// (handshake + headers per message) is precisely what we are measuring vs
// SSE/WebSocket persistence.

import { createServer } from 'node:http';

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

function readBody(req, limitBytes = 64 * 1024) {
    return new Promise((resolve, reject) => {
        let size = 0;
        const chunks = [];
        req.on('data', (chunk) => {
            size += chunk.length;
            if (size > limitBytes) {
                reject(new Error('payload too large'));
                req.destroy();
                return;
            }
            chunks.push(chunk);
        });
        req.on('end', () => resolve(Buffer.concat(chunks)));
        req.on('error', reject);
    });
}

const server = createServer(async (req, res) => {
    if (req.method !== 'POST' || req.url !== '/echo') {
        res.writeHead(404).end();
        return;
    }

    let body;
    try {
        body = await readBody(req);
    } catch (err) {
        res.writeHead(413).end(err.message);
        return;
    }

    // Strict echo: respond with the exact bytes received.
    res.writeHead(200, {
        'Content-Type': 'application/json',
        'Content-Length': body.length,
    });
    res.end(body);
});

server.on('listening', () => console.log(`polling echo listening on ${host}:${port}`));
server.on('error', (err) => {
    console.error('server error:', err);
    process.exit(1);
});
server.listen(port, host);

for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
        console.log(`received ${sig}, closing`);
        server.close(() => process.exit(0));
    });
}
