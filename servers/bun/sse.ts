// SSE echo server (Bun, native Bun.serve).
//
// Two endpoints:
//   GET  /events?clientId=<id>   open the persistent SSE stream
//   POST /send?clientId=<id>     submit a payload; server pushes it down the
//                                matching open stream
//
// A Map<clientId, controller> routes each POST's body to exactly one stream.

import { readFileSync } from 'node:fs';
import { join } from 'node:path';

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

const streams = new Map<string, ReadableStreamDefaultController<Uint8Array>>();
const encoder = new TextEncoder();

// TLS (https://) for a fair comparison vs WebTransport (which mandates TLS).
const certPem = readFileSync(join(import.meta.dir, '../cert.pem'), 'utf-8');
const keyPem  = readFileSync(join(import.meta.dir, '../key.pem'),  'utf-8');

Bun.serve({
    hostname: host,
    port,
    tls: { cert: certPem, key: keyPem },
    async fetch(req) {
        const url = new URL(req.url);

        if (req.method === 'GET' && url.pathname === '/events') {
            const clientId = url.searchParams.get('clientId');
            if (!clientId) return new Response('clientId required', { status: 400 });

            const body = new ReadableStream<Uint8Array>({
                start(controller) {
                    streams.set(clientId, controller);
                    // Bun.serve corks response headers with the first body chunk
                    // (oven-sh/bun#15574, discussion #13923). Without an initial
                    // enqueue the client's EventSource never sees the 200 OK and
                    // onopen never fires. An SSE comment line is a no-op for the
                    // EventSource parser but forces the header flush.
                    controller.enqueue(encoder.encode(': ok\n\n'));
                    console.log(`stream open ${clientId} (active=${streams.size})`);
                },
                cancel() {
                    streams.delete(clientId);
                    console.log(`stream close ${clientId} (active=${streams.size})`);
                },
            });

            return new Response(body, {
                headers: {
                    'Content-Type': 'text/event-stream',
                    'Cache-Control': 'no-cache, no-transform',
                    Connection: 'keep-alive',
                    'X-Accel-Buffering': 'no',
                },
            });
        }

        if (req.method === 'POST' && url.pathname === '/send') {
            const clientId = url.searchParams.get('clientId');
            if (!clientId) return new Response('clientId required', { status: 400 });

            const controller = streams.get(clientId);
            if (!controller) return new Response('no open stream for clientId', { status: 409 });

            const body = await req.text();
            // Strict echo: push exact bytes down the matching stream only.
            controller.enqueue(encoder.encode(`data: ${body}\n\n`));
            return new Response(null, { status: 204 });
        }

        return new Response(null, { status: 404 });
    },
});

console.log(`sse echo listening on ${host}:${port}`);
