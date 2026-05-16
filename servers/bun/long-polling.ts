// Long-polling echo server (Bun, native Bun.serve).
//
// Two endpoints, both keyed by ?clientId=<id>:
//   GET  /?clientId=<id>   the server holds this response open ("hanging GET")
//                          until a matching POST arrives, then completes the
//                          GET with the POST body.
//   POST /?clientId=<id>   the server immediately replies 204 to the POST and
//                          resolves the matching hanging GET with the body.
//                          409 if no GET is currently waiting for clientId.

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

interface Pending {
    resolve: (body: Uint8Array | null) => void;
}

const pending = new Map<string, Pending>();

Bun.serve({
    hostname: host,
    port,
    async fetch(req) {
        const url = new URL(req.url);
        const clientId = url.searchParams.get('clientId');
        if (!clientId) return new Response('clientId required', { status: 400 });

        if (req.method === 'GET') {
            const previous = pending.get(clientId);
            if (previous) previous.resolve(null);

            let resolve!: (body: Uint8Array | null) => void;
            const bodyPromise = new Promise<Uint8Array | null>((res) => { resolve = res; });
            pending.set(clientId, { resolve });

            req.signal.addEventListener('abort', () => {
                const cur = pending.get(clientId);
                if (cur && cur.resolve === resolve) {
                    pending.delete(clientId);
                    resolve(null);
                }
            });

            const body = await bodyPromise;
            if (body === null) {
                return new Response('hanging GET superseded or cancelled', { status: 409 });
            }
            return new Response(body, {
                status: 200,
                headers: {
                    'Content-Type': 'application/json',
                    'Content-Length': String(body.byteLength),
                },
            });
        }

        if (req.method === 'POST') {
            const body = new Uint8Array(await req.arrayBuffer());
            const waiter = pending.get(clientId);
            if (!waiter) {
                return new Response('no hanging GET for clientId', { status: 409 });
            }
            pending.delete(clientId);
            waiter.resolve(body);
            return new Response(null, { status: 204 });
        }

        return new Response(null, { status: 405 });
    },
});

console.log(`long-polling echo listening on ${host}:${port}`);
