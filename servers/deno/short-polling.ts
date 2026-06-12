// Long-polling echo server (Deno, native Deno.serve).
//
// Single endpoint: POST /echo
//   Body: 30-byte JSON payload from the client.
//   Response: the exact same bytes, Content-Type application/json.

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

// TLS (https://) for a fair comparison vs WebTransport; same cert idiom as webtransport.ts.
const certDir = new URL('../', import.meta.url);
const cert = await Deno.readTextFile(new URL('cert.pem', certDir));
const key = await Deno.readTextFile(new URL('key.pem', certDir));

Deno.serve({ hostname: host, port, cert, key }, async (req) => {
    if (req.method !== 'POST' || new URL(req.url).pathname !== '/echo') {
        return new Response(null, { status: 404 });
    }

    // Read raw bytes — never decode/re-encode, so the wire payload is
    // byte-identical to what arrived.
    const body = new Uint8Array(await req.arrayBuffer());

    return new Response(body, {
        status: 200,
        headers: {
            'Content-Type': 'application/json',
            'Content-Length': String(body.byteLength),
        },
    });
});

console.log(`polling echo listening on ${host}:${port}`);
