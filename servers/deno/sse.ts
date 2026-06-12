// SSE echo server (Deno, native Deno.serve).
//
// Two endpoints:
//   GET  /events?clientId=<id>   open the persistent SSE stream
//   POST /send?clientId=<id>     submit a payload; server pushes it down the
//                                matching open stream
//
// A Map<clientId, controller> routes each POST's body to exactly one stream.

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

const streams = new Map<string, ReadableStreamDefaultController<Uint8Array>>();
const encoder = new TextEncoder();

// TLS (https://) for a fair comparison vs WebTransport; same cert idiom as webtransport.ts.
const certDir = new URL('../', import.meta.url);
const cert = await Deno.readTextFile(new URL('cert.pem', certDir));
const key = await Deno.readTextFile(new URL('key.pem', certDir));

Deno.serve({ hostname: host, port, cert, key }, (req) => {
    const url = new URL(req.url);

    if (req.method === 'GET' && url.pathname === '/events') {
        const clientId = url.searchParams.get('clientId');
        if (!clientId) return new Response('clientId required', { status: 400 });

        const body = new ReadableStream<Uint8Array>({
            start(controller) {
                streams.set(clientId, controller);
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

        return req.text().then((body) => {
            // Strict echo: push exact bytes down the matching stream only.
            controller.enqueue(encoder.encode(`data: ${body}\n\n`));
            return new Response(null, { status: 204 });
        });
    }

    return new Response(null, { status: 404 });
});

console.log(`sse echo listening on ${host}:${port}`);
