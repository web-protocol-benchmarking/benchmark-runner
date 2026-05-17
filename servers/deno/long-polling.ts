// Long-polling echo server (Deno, native Deno.serve).
//
// Two endpoints, both keyed by ?clientId=<id>:
//   GET  /?clientId=<id>   the server holds this response open ("hanging GET")
//                          until a matching POST arrives, then completes the
//                          GET with the POST body.
//   POST /?clientId=<id>   the server immediately replies 204 to the POST and
//                          resolves the matching hanging GET with the body.
//                          409 if no GET is currently waiting for clientId.
//
// Implementation note: Deno.serve handlers can return a Promise<Response>, so
// a hanging GET is just a handler that awaits a per-clientId deferred. The
// POST handler looks up the deferred and resolves it, which causes the GET
// handler to return its Response — Deno writes it to the socket.

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

interface Pending {
    resolve: (body: Uint8Array | null) => void;
}

const pending = new Map<string, Pending>();

Deno.serve({ hostname: host, port }, async (req) => {
    const url = new URL(req.url);
    const clientId = url.searchParams.get('clientId');
    if (!clientId) return new Response('clientId required', { status: 400 });

    if (req.method === 'GET') {
        // If a previous hanging GET is still registered for this clientId,
        // resolve it with null so it returns a 409 — never silently leak.
        const previous = pending.get(clientId);
        if (previous) previous.resolve(null);

        // Use a deferred so the POST handler can resolve this GET's body.
        let resolve!: (body: Uint8Array | null) => void;
        const bodyPromise = new Promise<Uint8Array | null>((res) => { resolve = res; });
        pending.set(clientId, { resolve });

        // If the client disconnects, drop the registration.
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
        return new Response(body.buffer as ArrayBuffer, {
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
});

console.log(`long-polling echo listening on ${host}:${port}`);
