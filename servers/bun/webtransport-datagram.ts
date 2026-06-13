// WebTransport DATAGRAM echo server (Bun, @webtransport-bun/webtransport — Rust/napi-rs backend).
// Requires `bun install` in servers/bun/ to compile the native binding from source.
//
// Unlike the reliable-stream variant (webtransport-vmeansdev.ts), this echoes
// unreliable, unordered QUIC datagrams: every datagram received on the session
// is written straight back via sendDatagram(). A dropped datagram is simply
// lost — no retransmit, no head-of-line blocking. The server is a pure byte
// echo; the client's 4-byte seq prefix rides through untouched.

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createServer } from '@webtransport-bun/webtransport';

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

const certPem = readFileSync(join(import.meta.dir, '../cert.pem'), 'utf-8');
const keyPem  = readFileSync(join(import.meta.dir, '../key.pem'),  'utf-8');

async function handleSession(session: any): Promise<void> {
    console.log('conn open');
    try {
        for await (const d of session.incomingDatagrams()) {
            await session.sendDatagram(d);
        }
    } catch {
        // Session closed by client — normal on benchmark end.
    }
    console.log('conn close');
}

createServer({
    host,
    port,
    tls: { certPem, keyPem },
    onSession: (session: any) => { handleSession(session); },
    // Raise rate limits so the library's token buckets don't throttle the benchmark:
    //  - handshakes: 50 clients connect near-simultaneously.
    //  - datagrams: the library default is only datagramsPerSec=2000 / burst=5000,
    //    which silently CAPS datagram throughput at ~2000/s (token-bucket) regardless
    //    of client count or CPU — the server sits ~17% idle — and drops the overflow.
    //    node's @fails-components and deno's native WebTransport impose no datagram
    //    rate limit, so leaving bun's default would measure bun's rate limiter rather
    //    than its datagram transport. Set effectively-unlimited for a fair comparison.
    //    (Reliable-stream bun WT is unaffected: it opens one long-lived stream per
    //    client, so streamsPerSec never binds — only per-datagram sends are limited.)
    rateLimits: {
        handshakesPerSec: 200, handshakesBurst: 200,
        datagramsPerSec: 100_000_000, datagramsBurst: 100_000_000,
    },
});

console.log(`webtransport datagram echo listening on ${host}:${port}`);

for (const sig of ['SIGINT', 'SIGTERM'] as const) {
    process.on(sig, () => {
        console.log(`received ${sig}, closing`);
        process.exit(0);
    });
}
