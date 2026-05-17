// WebTransport echo server (Bun, @fails-components/webtransport — libquiche N-API backend).
// Uses Bun's Node.js compatibility layer to run the @fails-components npm package.
//
// Accepts bidirectional streams and echoes every chunk back immediately.
// A single bidi stream is held open for the full benchmark run.

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
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

await quicheLoaded;

const cert = readFileSync(join(import.meta.dir, '../cert.pem'), 'utf8');
const privKey = readFileSync(join(import.meta.dir, '../key.pem'), 'utf8');

const server = new Http3Server({ port, host, secret: 'benchmark', cert, privKey });
server.startServer();
await server.ready;
console.log(`webtransport echo listening on ${host}:${port}`);

async function handleStream(stream: { readable: ReadableStream; writable: WritableStream }): Promise<void> {
    try {
        await stream.readable.pipeTo(stream.writable);
    } catch {
        // Client closed the stream — normal on benchmark end.
    }
}

async function handleSession(session: any): Promise<void> {
    console.log('conn open');
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
    console.log('conn close');
}

const sessionReader = (server.sessionStream('/') as ReadableStream).getReader();
(async () => {
    while (true) {
        const { value: session, done } = await sessionReader.read();
        if (done) break;
        handleSession(session);
    }
})();

for (const sig of ['SIGINT', 'SIGTERM'] as const) {
    process.on(sig, () => {
        console.log(`received ${sig}, closing`);
        server.stopServer();
        process.exit(0);
    });
}
