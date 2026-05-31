// WebTransport echo server (Bun, @webtransport-bun/webtransport — Rust/napi-rs backend).
// Requires `bun install` in servers/bun/ to compile the native binding from source.
//
// Accepts bidirectional streams and echoes every chunk back immediately.
// A single bidi stream is held open for the full benchmark run.

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
        for await (const stream of session.incomingBidirectionalStreams) {
            // Fire-and-forget per stream so we keep accepting new ones.
            stream.readable.pipeTo(stream.writable).catch(() => {});
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
    // Raise handshake rate limits so 50 simultaneous clients don't get 429.
    rateLimits: { handshakesPerSec: 200, handshakesBurst: 200 },
});

console.log(`webtransport echo listening on ${host}:${port}`);

for (const sig of ['SIGINT', 'SIGTERM'] as const) {
    process.on(sig, () => {
        console.log(`received ${sig}, closing`);
        process.exit(0);
    });
}
