declare module '@fails-components/webtransport' {
    export const quicheLoaded: Promise<void>;
    export class Http3Server {
        constructor(opts: { port: number; host: string; secret: string; cert: string; privKey: string });
        startServer(): void;
        stopServer(): void;
        readonly ready: Promise<void>;
        sessionStream(path: string): ReadableStream;
    }
}
