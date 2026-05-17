// WebTransport echo server (Node.js, @fails-components/webtransport).
// Requires @fails-components/webtransport-transport-http3-quiche for the
// libquiche-backed HTTP/3 transport (prebuilt linux-arm64 binary available).
//
// Accepts bidirectional streams and echoes every chunk back immediately.
// A single bidi stream is held open for the full benchmark run.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { quicheLoaded, Http3Server } from '@fails-components/webtransport';

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

// Wait for the native quiche module to finish loading before binding.
await quicheLoaded;

const dir = dirname(fileURLToPath(import.meta.url));
const cert = readFileSync(join(dir, '../cert.pem'), 'utf8');
const privKey = readFileSync(join(dir, '../key.pem'), 'utf8');

const server = new Http3Server({ port, host, secret: 'benchmark', cert, privKey });
server.startServer();
await server.ready;
console.log(`webtransport echo listening on ${host}:${port}`);

async function handleStream(stream) {
    try {
        await stream.readable.pipeTo(stream.writable);
    } catch {
        // Client closed the stream — normal on benchmark end.
    }
}

async function handleSession(session) {
    console.log(`conn open`);
    try {
        const reader = session.incomingBidirectionalStreams.getReader();
        while (true) {
            const { value: stream, done } = await reader.read();
            if (done) break;
            handleStream(stream);
        }
    } catch {
        // Session closed.
    }
    console.log(`conn close`);
}

const sessionReader = server.sessionStream('/').getReader();
(async () => {
    while (true) {
        const { value: session, done } = await sessionReader.read();
        if (done) break;
        handleSession(session);
    }
})();

for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
        console.log(`received ${sig}, closing`);
        server.stopServer();
        process.exit(0);
    });
}
