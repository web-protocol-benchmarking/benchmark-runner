// WebTransport DATAGRAM echo server (Node.js, @fails-components/webtransport).
// Requires @fails-components/webtransport-transport-http3-quiche for the
// libquiche-backed HTTP/3 transport (prebuilt linux-arm64 binary available).
//
// Unlike the reliable-stream variant (webtransport-fails-components.js), this
// echoes unreliable, unordered QUIC datagrams: every datagram received on the
// session is written straight back. A dropped datagram is simply lost — no
// retransmit, no head-of-line blocking. The send side uses datagrams.createWritable()
// (the @fails-components datagram-write API). The server is a pure byte echo;
// the client's 4-byte seq prefix rides through untouched.

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
console.log(`webtransport datagram echo listening on ${host}:${port}`);

async function handleSession(session) {
    console.log(`conn open`);
    try {
        const reader = session.datagrams.readable.getReader();
        const writer = session.datagrams.createWritable().getWriter();
        while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            await writer.write(value);
        }
    } catch {
        // Session closed by client — normal on benchmark end.
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
