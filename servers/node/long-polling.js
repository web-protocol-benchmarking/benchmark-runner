// Long-polling echo server (Node.js, ESM).
//
// Two endpoints, both keyed by ?clientId=<id>:
//   GET  /?clientId=<id>   the server holds this response open ("hanging GET")
//                          until a matching POST arrives, then writes the POST
//                          body as the GET response.
//   POST /?clientId=<id>   the server immediately responds 200 OK, then
//                          resolves the matching hanging GET with the POST
//                          body. If no GET is currently registered for this
//                          clientId, returns 409 (no buffering, no silent drop).
//
// Strict echo: only the GET registered under the matching clientId receives
// the payload, and it receives the exact bytes from the POST.

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

// clientId -> hanging GET ServerResponse
const pending = new Map();

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
    const url = new URL(req.url, 'http://placeholder');
    const clientId = url.searchParams.get('clientId');
    if (!clientId) {
        res.writeHead(400).end('clientId required');
        return;
    }

    if (req.method === 'GET') {
        // Register the hanging response. If the client opens a second GET
        // before its previous one resolves, the new one replaces the old —
        // the old one is closed without a body so the client sees an error
        // rather than silently waiting forever.
        const previous = pending.get(clientId);
        if (previous) {
            previous.writeHead(409).end();
        }
        pending.set(clientId, res);
        req.on('close', () => {
            if (pending.get(clientId) === res) pending.delete(clientId);
        });
        return;
    }

    if (req.method === 'POST') {
        let body;
        try {
            body = await readBody(req);
        } catch (err) {
            res.writeHead(413).end(err.message);
            return;
        }

        const hangingRes = pending.get(clientId);
        if (!hangingRes) {
            res.writeHead(409).end('no hanging GET for clientId');
            return;
        }
        pending.delete(clientId);

        // Resolve the hanging GET with the exact POST bytes.
        hangingRes.writeHead(200, {
            'Content-Type': 'application/json',
            'Content-Length': body.length,
        });
        hangingRes.end(body);

        // Acknowledge the POST after the GET resolution is queued.
        res.writeHead(204).end();
        return;
    }

    res.writeHead(405).end();
});

server.on('listening', () => console.log(`long-polling echo listening on ${host}:${port}`));
server.on('error', (err) => {
    console.error('server error:', err);
    process.exit(1);
});
server.listen(port, host);

for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
        console.log(`received ${sig}, closing`);
        for (const r of pending.values()) {
            try { r.end(); } catch { /* ignore */ }
        }
        server.close(() => process.exit(0));
    });
}
