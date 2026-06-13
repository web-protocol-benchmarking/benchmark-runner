// Load generator for the benchmark-runner thesis suite.
//
// Runs under Deno (native TS + fetch + WebSocket + EventSource). Each run:
//   * spawns N concurrent clients of one protocol (ws | sse | polling)
//   * each client runs a closed-loop depth=1 echo: send payload, await echo,
//     record RTT with performance.now(), send next
//   * after --duration seconds, signals all clients to stop, merges per-client
//     RTT buffers, computes exact p50/p95/p99 from the sorted samples
//   * appends a summary row to results/metrics.csv (created with header on
//     first run) and writes results/<run_tag>/rtts.csv with every sample
//
// Architecture: ProtocolClient interface + one class per protocol. Adding
// HTTP/3 / WebTransport in Phase 2 means adding a WebTransportClient class
// and one switch-case entry — nothing else changes.
//
// Usage:
//   deno run --allow-net --allow-read --allow-write --allow-env \
//     client/load_generator.ts \
//     --target 10.0.0.1:8080 --protocol ws --duration 30 --clients 8

// ============================================================================
// CLI parsing
// ============================================================================

type Protocol = 'ws' | 'sse' | 'short-polling' | 'long-polling' | 'webtransport' | 'webtransport-datagram';

interface Args {
    target: string;       // "host:port"
    protocol: Protocol;
    duration: number;     // seconds
    clients: number;      // concurrency
    resultsDir: string;   // where rtts.csv + metrics.csv live
    // Self-describing dimensions, injected by the harness via RUN_* env vars.
    // When run standalone (no harness), these fall back to safe placeholders so
    // the metrics row is still well-formed.
    profile: string;          // ideal | high_latency | packet_loss | crossover | profiling | smoke | standalone
    runtime: string;          // node | deno | bun | unknown
    protocolVariant: string;  // full variant (e.g. webtransport-fails-components); defaults to protocol
    packetLossPct: string;    // numeric string, or "" if unknown
    delayMs: string;          // numeric string, or "" if unknown
}

function parseArgs(argv: string[]): Args {
    const map = new Map<string, string>();
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (!a.startsWith('--')) continue;
        const key = a.slice(2);
        const val = argv[i + 1];
        if (val === undefined || val.startsWith('--')) {
            throw new Error(`flag --${key} requires a value`);
        }
        map.set(key, val);
        i++;
    }

    const get = (k: string): string => {
        const v = map.get(k);
        if (v === undefined) throw new Error(`missing required flag --${k}`);
        return v;
    };

    const protocol = get('protocol') as Protocol;
    if (
        protocol !== 'ws' &&
        protocol !== 'sse' &&
        protocol !== 'short-polling' &&
        protocol !== 'long-polling' &&
        protocol !== 'webtransport' &&
        protocol !== 'webtransport-datagram'
    ) {
        throw new Error(`--protocol must be one of: ws, sse, short-polling, long-polling, webtransport, webtransport-datagram`);
    }

    const duration = Number(get('duration'));
    if (!Number.isFinite(duration) || duration <= 0) {
        throw new Error(`--duration must be a positive number`);
    }

    const clients = Number(get('clients'));
    if (!Number.isInteger(clients) || clients <= 0) {
        throw new Error(`--clients must be a positive integer`);
    }

    // RESULTS_DIR is set by harness_run_test.sh per-run; fall back to ./results.
    const resultsDir = map.get('results-dir') ?? Deno.env.get('RESULTS_DIR') ?? './results';

    // Self-describing dimensions injected by the harness (harness_run_test.sh).
    // Standalone runs (no harness) get placeholders so the row stays well-formed.
    const env = (k: string): string => Deno.env.get(k) ?? '';
    const profile = env('RUN_PROFILE') || 'standalone';
    const runtime = env('RUN_RUNTIME') || 'unknown';
    const protocolVariant = env('RUN_VARIANT') || protocol;
    const packetLossPct = env('RUN_LOSS_PCT'); // "" if unset
    const delayMs = env('RUN_DELAY_MS');       // "" if unset

    return {
        target: get('target'), protocol, duration, clients, resultsDir,
        profile, runtime, protocolVariant, packetLossPct, delayMs,
    };
}

// ============================================================================
// Payload
// ============================================================================
//
// {"id":<int>,"client_time":<timestamp>} — the prompt specifies a 30-byte
// payload. With id and client_time as integers (ms since epoch), the exact
// length depends on their digit counts; that is fine for transport tests.
// The same encoding is used across all protocols so the wire payload is
// identical.

function makePayload(id: number, clientTimeMs: number): string {
    return `{"id":${id},"client_time":${clientTimeMs}}`;
}

// ============================================================================
// Per-client RTT buffer
// ============================================================================
//
// Each client owns a pre-sized Float64Array so worker loops never reallocate.
// The cap is generous: even an unloaded loopback echo tops out around a few
// hundred thousand msgs/sec/client; under netem with real RTT it will be far
// less. If a client ever hits the cap we stop recording (not stop sending)
// and bump an overflow counter for the summary.

const RTT_CAP_PER_CLIENT = 5_000_000;

class RttBuffer {
    readonly data: Float64Array;
    length = 0;
    overflows = 0;

    constructor(cap: number = RTT_CAP_PER_CLIENT) {
        this.data = new Float64Array(cap);
    }

    push(rttMs: number): void {
        if (this.length >= this.data.length) {
            this.overflows++;
            return;
        }
        this.data[this.length++] = rttMs;
    }
}

// ============================================================================
// ProtocolClient interface
// ============================================================================
//
// Every protocol implementation:
//   * runs its echo loop until `stopSignal.aborted`
//   * pushes each completed RTT (ms) into its RttBuffer
//   * records connection time (ms from start-of-connect to ready-to-send)
//   * counts errors by category but keeps running
//
// Phase 2: a WebTransportClient implements this same interface.

interface ClientStats {
    connectTimeMs: number;       // -1 if connection failed entirely
    echoesOk: number;
    errors: number;
    rtts: RttBuffer;
}

interface ProtocolClient {
    run(stopSignal: AbortSignal): Promise<ClientStats>;
}

// ============================================================================
// WebSocket client
// ============================================================================

class WebSocketClient implements ProtocolClient {
    constructor(private readonly target: string, private readonly clientId: number) {}

    run(stopSignal: AbortSignal): Promise<ClientStats> {
        const stats: ClientStats = { connectTimeMs: -1, echoesOk: 0, errors: 0, rtts: new RttBuffer() };

        return new Promise((resolve) => {
            const connectStart = performance.now();
            const ws = new WebSocket(`wss://${this.target}/`);
            let sendStart = 0;
            let nextId = 0;
            let settled = false;

            const finish = () => {
                if (settled) return;
                settled = true;
                stopSignal.removeEventListener('abort', onAbort);
                try { ws.close(); } catch { /* ignore */ }
                resolve(stats);
            };

            const onAbort = () => finish();
            stopSignal.addEventListener('abort', onAbort);

            const sendNext = () => {
                if (stopSignal.aborted) { finish(); return; }
                sendStart = performance.now();
                try {
                    ws.send(makePayload(nextId++, Date.now()));
                } catch {
                    stats.errors++;
                    finish();
                }
            };

            ws.onopen = () => {
                stats.connectTimeMs = performance.now() - connectStart;
                sendNext();
            };

            ws.onmessage = () => {
                stats.rtts.push(performance.now() - sendStart);
                stats.echoesOk++;
                sendNext();
            };

            ws.onerror = () => {
                stats.errors++;
                // Don't finish() here — onclose will fire and we resolve there
                // to ensure connectTimeMs is finalized correctly.
            };

            ws.onclose = () => finish();
        });
    }
}

// ============================================================================
// SSE client
// ============================================================================
//
// Two-channel protocol:
//   * EventSource holds GET /events?clientId=<id> open for the duration
//   * each echo cycle = POST /send?clientId=<id> then await the matching
//     `message` event back on the EventSource
//
// Closed-loop depth=1: the next POST is only issued after the previous echo
// arrives on the stream, so a single inflight resolver is sufficient.

class SseClient implements ProtocolClient {
    // http2: false pins the SEND path (the POST /send fetch) to HTTP/1.1 — see
    // LongPollingClient for the rationale. CAVEAT: the receive path is an
    // EventSource, and Deno's EventSource exposes no ALPN/version control, so the
    // event stream against the Deno server unavoidably negotiates h2 (node/bun only
    // offer h1.1, so they stay h1.1). This residual is minor — SSE's per-echo RTT
    // is ~2ms, i.e. it does NOT hit the ~42ms h2 hanging-response stall that
    // long-polling did — but it is documented for honesty in the methodology.
    private readonly httpClient: Deno.HttpClient = Deno.createHttpClient({ http2: false });

    constructor(private readonly target: string, private readonly clientId: number) {}

    run(stopSignal: AbortSignal): Promise<ClientStats> {
        const stats: ClientStats = { connectTimeMs: -1, echoesOk: 0, errors: 0, rtts: new RttBuffer() };
        const idParam = `bench-${this.clientId}-${Date.now()}`;
        const base = `https://${this.target}`;
        const eventsUrl = `${base}/events?clientId=${idParam}`;
        const sendUrl = `${base}/send?clientId=${idParam}`;

        return new Promise((resolve) => {
            const connectStart = performance.now();
            const es = new EventSource(eventsUrl);
            let pendingResolve: (() => void) | null = null;
            let nextId = 0;
            let settled = false;

            const finish = () => {
                if (settled) return;
                settled = true;
                stopSignal.removeEventListener('abort', onAbort);
                try { es.close(); } catch { /* ignore */ }
                try { this.httpClient.close(); } catch { /* ignore */ }
                resolve(stats);
            };

            const onAbort = () => finish();
            stopSignal.addEventListener('abort', onAbort);

            es.onopen = async () => {
                stats.connectTimeMs = performance.now() - connectStart;
                // Closed-loop send/recv until stop.
                while (!stopSignal.aborted) {
                    const sendStart = performance.now();
                    const payload = makePayload(nextId++, Date.now());

                    const echoArrived = new Promise<void>((res) => { pendingResolve = res; });

                    try {
                        const r = await fetch(sendUrl, {
                            method: 'POST',
                            body: payload,
                            headers: { 'Content-Type': 'application/json' },
                            client: this.httpClient,
                        });
                        if (!r.ok) {
                            stats.errors++;
                            pendingResolve = null;
                            // Brief yield so we don't tight-loop on a dead server.
                            await new Promise((res) => setTimeout(res, 1));
                            continue;
                        }
                        // Drain the body so the connection can return to the pool.
                        await r.body?.cancel();
                    } catch {
                        stats.errors++;
                        pendingResolve = null;
                        continue;
                    }

                    await echoArrived;
                    if (stopSignal.aborted) break;
                    stats.rtts.push(performance.now() - sendStart);
                    stats.echoesOk++;
                }
                finish();
            };

            es.onmessage = () => {
                const r = pendingResolve;
                pendingResolve = null;
                r?.();
            };

            es.onerror = () => {
                stats.errors++;
                // Terminate on any error after the stream has been established.
                // EventSource will silently auto-reconnect otherwise, baking
                // TCP handshake latency into subsequent RTTs and corrupting
                // the percentile data under tc netem packet loss.
                if (stats.connectTimeMs < 0 || stats.echoesOk > 0) finish();
            };
        });
    }
}

// ============================================================================
// Short-polling client
// ============================================================================
//
// Each iteration = one fresh POST /echo cycle. With HTTP keep-alive Deno's
// fetch will reuse the underlying TCP connection across iterations, so the
// TCP/TLS handshake cost is paid once per client (visible in connectTimeMs
// via the first POST). Disable keep-alive externally if you want per-request
// handshake costs measured per iteration.

class ShortPollingClient implements ProtocolClient {
    // http2: false pins this client to HTTP/1.1 — see LongPollingClient for the
    // full rationale. The TLS Deno servers advertise h2 in ALPN (node/bun do
    // not), so without the pin the Deno client upgrades to h2 *only* against the
    // Deno server, paying ~1.8x the per-request cost (measured) and breaking the
    // cross-runtime comparison. Pinning keeps "short-polling over TLS" on the same
    // wire protocol (HTTP/1.1 + TLS) against all three runtimes.
    private readonly httpClient: Deno.HttpClient = Deno.createHttpClient({ http2: false });

    constructor(private readonly target: string, private readonly clientId: number) {}

    async run(stopSignal: AbortSignal): Promise<ClientStats> {
        const stats: ClientStats = { connectTimeMs: -1, echoesOk: 0, errors: 0, rtts: new RttBuffer() };
        const url = `https://${this.target}/echo`;
        let nextId = 0;
        const connectStart = performance.now();
        let firstRequest = true;

        while (!stopSignal.aborted) {
            const sendStart = performance.now();
            try {
                const r = await fetch(url, {
                    method: 'POST',
                    body: makePayload(nextId++, Date.now()),
                    headers: { 'Content-Type': 'application/json' },
                    client: this.httpClient,
                });
                if (!r.ok) {
                    stats.errors++;
                    await r.body?.cancel();
                    continue;
                }
                await r.text();  // drain
                const now = performance.now();
                if (firstRequest) {
                    stats.connectTimeMs = now - connectStart;
                    firstRequest = false;
                }
                stats.rtts.push(now - sendStart);
                stats.echoesOk++;
            } catch {
                stats.errors++;
            }
        }
        this.httpClient.close();
        return stats;
    }
}

// ============================================================================
// Long-polling client
// ============================================================================
//
// Per iteration:
//   1. Open a hanging GET /?clientId=<id> (server holds this open).
//   2. POST /?clientId=<id> with the payload, t_send = performance.now()
//      captured immediately before the POST is issued.
//   3. The server resolves the hanging GET with the POST body; await its
//      completion. RTT = t_recv - t_send.
//   4. Loop.
//
// The GET is opened first so the server's POST handler never has to buffer
// payloads — it always finds a registered hanging response to resolve. If the
// server returns 409 (no waiter / superseded GET), we count it as an error
// and continue without polluting the RTT array.
//
// Note: this measures the server-side "hold + resolve" path, which is the
// distinguishing characteristic of long polling vs short polling. Connect
// time is recorded on the first successful echo so it reflects an established
// transport, matching the short-polling methodology.

class LongPollingClient implements ProtocolClient {
    // Each instance gets its own 2-slot HTTP connection pool so the hanging
    // GET and the POST don't compete with other clients for the global pool.
    // Without isolation, 50 clients × 2 concurrent requests = 100 connections
    // deadlock the shared pool: GETs hold all slots, POSTs can never connect.
    //
    // http2: false pins this client to HTTP/1.1. The TLS servers all advertise
    // BOTH h2 and http/1.1 in ALPN — but only Deno.serve does (node's https is
    // HTTP/1.1-only, bun serves HTTP/1.1). Without this pin, the Deno client
    // opportunistically upgrades to h2 *only* against the Deno server, where the
    // hanging-GET/paired-POST choreography hits an ~42ms h2 frame-flush stall per
    // round trip (a ~40ms delayed-ACK-class timer, measured even on loopback),
    // collapsing throughput ~9x vs node/bun. Pinning h1.1 makes "long-polling over
    // TLS" mean the same wire protocol (HTTP/1.1 + TLS) against all three runtimes,
    // restoring an apples-to-apples comparison. node/bun paths are unaffected
    // (they only ever offered h1.1).
    private readonly httpClient: Deno.HttpClient = Deno.createHttpClient({ poolSize: 2, http2: false });

    constructor(private readonly target: string, private readonly clientId: number) {}

    async run(stopSignal: AbortSignal): Promise<ClientStats> {
        const stats: ClientStats = { connectTimeMs: -1, echoesOk: 0, errors: 0, rtts: new RttBuffer() };
        const idParam = `bench-${this.clientId}-${Date.now()}`;
        const base = `https://${this.target}`;
        const getUrl = `${base}/?clientId=${idParam}`;
        const postUrl = `${base}/?clientId=${idParam}`;
        let nextId = 0;
        const connectStart = performance.now();
        let firstEcho = true;

        while (!stopSignal.aborted) {
            // Open hanging GET first; the server will only respond once the
            // matching POST arrives. A per-iteration AbortController lets us cancel
            // THIS GET if its paired POST fails (see below); AbortSignal.any folds in
            // the run-wide stopSignal so end-of-run still aborts it.
            const getAbort = new AbortController();
            const getPromise = fetch(getUrl, {
                method: 'GET',
                client: this.httpClient,
                signal: AbortSignal.any([stopSignal, getAbort.signal]),
            });
            // Suppress unhandled-rejection in the microtask gap between here and
            // the `await getPromise` below — the rejection is re-thrown there.
            getPromise.catch(() => {});

            // Tiny yield so the GET hits the server before the POST. Without
            // this, both requests can race and the POST occasionally arrives
            // first, drawing a 409.
            await new Promise((res) => setTimeout(res, 0));

            const sendStart = performance.now();
            let postOk = false;
            try {
                const postRes = await fetch(postUrl, {
                    method: 'POST',
                    body: makePayload(nextId++, Date.now()),
                    headers: { 'Content-Type': 'application/json' },
                    client: this.httpClient,
                    signal: stopSignal,
                });
                if (!postRes.ok) {
                    stats.errors++;
                    await postRes.body?.cancel();
                } else {
                    await postRes.body?.cancel();
                    postOk = true;
                }
            } catch (e) {
                if ((e as Error).name !== 'AbortError') stats.errors++;
            }

            // If the POST never delivered, the server is holding the hanging GET
            // open waiting for a matching POST that will never come — `await
            // getPromise` would then block until end-of-run, burning the whole run
            // as a 0-sample deadlock (observed under cold-TLS warmup races). Cancel
            // the orphaned GET so the loop recovers and retries; the server drops its
            // pending entry on the GET's abort.
            if (!postOk) getAbort.abort();

            // Always await the GET so it doesn't leak, even if the POST failed.
            try {
                const getRes = await getPromise;
                if (!getRes.ok) {
                    if (postOk) stats.errors++;  // POST ok but GET 409 — server desync
                    await getRes.body?.cancel();
                    continue;
                }
                await getRes.text();  // drain echoed body
                if (!postOk) continue;  // don't record RTT if the POST never made it
                const now = performance.now();
                if (firstEcho) {
                    stats.connectTimeMs = now - connectStart;
                    firstEcho = false;
                }
                stats.rtts.push(now - sendStart);
                stats.echoesOk++;
            } catch (e) {
                if ((e as Error).name !== 'AbortError') stats.errors++;
            }
        }
        this.httpClient.close();
        return stats;
    }
}

// ============================================================================
// WebTransport client
// ============================================================================
//
// Requires --unstable-net. Uses a single bidirectional stream held open for
// the full benchmark run. Closed-loop depth=1: write payload, await echo,
// record RTT, repeat — identical methodology to WebSocketClient.
//
// serverCertificateHashes authenticates the self-signed cert by its SHA-256
// fingerprint instead of the Web PKI chain, which is the correct approach for
// a controlled test network. The hash ArrayBuffer is computed once in main()
// and passed to every client instance.

function decodePemToDer(pem: string): Uint8Array {
    const b64 = pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
    return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

class WebTransportClient implements ProtocolClient {
    constructor(
        private readonly target: string,
        private readonly clientId: number,
        private readonly certHash: ArrayBuffer,
    ) {}

    async run(stopSignal: AbortSignal): Promise<ClientStats> {
        const stats: ClientStats = { connectTimeMs: -1, echoesOk: 0, errors: 0, rtts: new RttBuffer() };
        const encoder = new TextEncoder();

        const connectStart = performance.now();
        let wt: WebTransport;
        try {
            wt = new WebTransport(`https://${this.target}`, {
                serverCertificateHashes: [{ algorithm: 'sha-256', value: this.certHash }],
                allowPooling: false,
            });
            // Consume wt.closed's rejection. On a handshake timeout under loss
            // both wt.ready AND wt.closed reject; the catch below handles ready,
            // but an unhandled wt.closed rejection would crash the whole Deno
            // process (taking the other 49 clients with it). No-op handler only
            // — this changes nothing about the echo loop, depth, or streams.
            wt.closed.catch(() => { /* recorded via the ready/echo paths */ });
            await wt.ready;
        } catch (err) {
            stats.errors++;
            console.error(`[wt client ${this.clientId}] connect failed:`, err);
            return stats;
        }
        stats.connectTimeMs = performance.now() - connectStart;

        let stream: { readable: ReadableStream<Uint8Array>; writable: WritableStream<Uint8Array> };
        try {
            stream = await wt.createBidirectionalStream();
        } catch {
            stats.errors++;
            wt.close();
            return stats;
        }

        const writer = stream.writable.getWriter();
        const reader = stream.readable.getReader();

        const onAbort = () => {
            try { wt.close(); } catch { /* ignore */ }
        };
        stopSignal.addEventListener('abort', onAbort);

        try {
            while (!stopSignal.aborted) {
                const sendStart = performance.now();
                try {
                    await writer.write(encoder.encode(makePayload(this.clientId, Date.now())));
                    const { value, done } = await reader.read();
                    if (done) break;
                    if (value) {
                        stats.rtts.push(performance.now() - sendStart);
                        stats.echoesOk++;
                    }
                } catch {
                    if (!stopSignal.aborted) stats.errors++;
                    break;
                }
            }
        } finally {
            stopSignal.removeEventListener('abort', onAbort);
            try { await writer.close(); } catch { /* ignore */ }
            reader.releaseLock();
            try { wt.close(); } catch { /* ignore */ }
        }

        return stats;
    }
}

// ============================================================================
// WebTransport DATAGRAM client (unreliable, unordered)
// ============================================================================
//
// The reliable WebTransportClient above writes over a single bidirectional QUIC
// stream (in-order, retransmitted) — so under loss it stalls exactly like TCP.
// This variant uses the unreliable WebTransport Datagram API: a dropped datagram
// is simply lost (no retransmit, no head-of-line blocking), so the closed loop
// must tolerate losses rather than wait forever for them.
//
// Two problems an unreliable depth=1 loop must solve, and how this design does:
//   1. Deadlock — a naive `send; await read` blocks forever the first time a
//      request OR its echo is dropped. Fix: each send waits on a per-sequence
//      promise raced against DATAGRAM_RECV_TIMEOUT_MS; a timeout counts the
//      message as lost (errors++) and the loop continues to the next send.
//   2. RTT misattribution — racing read() against a timeout would leave the
//      abandoned read() pending; after a loss those orphaned reads pile up and a
//      later echo resolves the wrong waiter. Fix: a SINGLE persistent receiver
//      loop owns the only reader (never abandoned) and matches each echo to its
//      waiter by a 4-byte big-endian sequence prefix. A late echo whose waiter
//      already timed out matches nothing and is dropped.
//
// depth=1 is preserved: the sender writes exactly one datagram and waits for its
// echo (or timeout) before sending the next. The body is the same makePayload
// bytes as every other protocol, prefixed with the 4-byte seq (~42 bytes total,
// far under the ~1200-byte datagram limit). The server echoes raw bytes, so the
// prefix round-trips with no server-side parsing.
//
// DATAGRAM_RECV_TIMEOUT_MS is a methodological parameter: a datagram with no echo
// within this window is declared lost. Because datagrams are never retransmitted,
// at depth=1 this timeout IS the per-loss penalty (pure dead time — nothing else is
// in flight), so it dominates throughput under loss. It is set just above the
// measured successful-RTT distribution: even at 10% loss, datagram round trips that
// DO complete stay at ~105ms p50 / ~120ms p99 (loss only removes datagrams, it does
// not slow the survivors), so 150ms gives a small headroom over p99 while keeping the
// give-up fast. Trade-off: the ~1% tail of slow-but-not-lost datagrams above 150ms is
// counted as a (false) loss. Canary — if Errors at loss=0% is >0 after a run, the
// window is clipping legitimate slow echoes and should be raised (e.g. 250-400ms).

const DATAGRAM_RECV_TIMEOUT_MS = 150;

class WebTransportDatagramClient implements ProtocolClient {
    constructor(
        private readonly target: string,
        private readonly clientId: number,
        private readonly certHash: ArrayBuffer,
    ) {}

    async run(stopSignal: AbortSignal): Promise<ClientStats> {
        const stats: ClientStats = { connectTimeMs: -1, echoesOk: 0, errors: 0, rtts: new RttBuffer() };
        const encoder = new TextEncoder();

        const connectStart = performance.now();
        let wt: WebTransport;
        try {
            wt = new WebTransport(`https://${this.target}`, {
                serverCertificateHashes: [{ algorithm: 'sha-256', value: this.certHash }],
                allowPooling: false,
            });
            // Consume wt.closed's rejection (same rationale as WebTransportClient).
            wt.closed.catch(() => { /* recorded via the ready/echo paths */ });
            await wt.ready;
        } catch (err) {
            stats.errors++;
            console.error(`[wt-datagram client ${this.clientId}] connect failed:`, err);
            return stats;
        }
        stats.connectTimeMs = performance.now() - connectStart;

        const writer = wt.datagrams.writable.getWriter();
        const reader = wt.datagrams.readable.getReader();

        // Waiters keyed by sequence number; the receiver loop resolves them.
        const waiters = new Map<number, (arrivalMs: number) => void>();

        // Resolved once on abort so an in-flight send returns immediately rather
        // than blocking up to the full timeout during shutdown.
        let abortResolve: () => void = () => {};
        const abortPromise = new Promise<'abort'>((resolve) => { abortResolve = () => resolve('abort'); });
        const onAbort = () => {
            try { wt.close(); } catch { /* ignore */ }
            abortResolve();
        };
        stopSignal.addEventListener('abort', onAbort);

        // Persistent receiver: the only reader of the datagram stream. Decodes the
        // seq prefix of each echo and resolves the matching waiter (if its sender
        // has not already timed out). Never abandoned, so no read piles up.
        const receiveLoop = (async () => {
            try {
                while (true) {
                    const { value, done } = await reader.read();
                    if (done) break;
                    if (!value || value.byteLength < 4) continue;
                    const seq = new DataView(value.buffer, value.byteOffset, value.byteLength).getUint32(0, false);
                    const resolve = waiters.get(seq);
                    if (resolve) {
                        waiters.delete(seq);
                        resolve(performance.now());
                    }
                    // else: a late echo whose waiter already timed out — drop it.
                }
            } catch {
                // Reader closed on abort / connection end — normal shutdown.
            }
        })();

        try {
            let seq = 0;
            while (!stopSignal.aborted) {
                seq++;
                // [4-byte big-endian seq | makePayload bytes]
                const body = encoder.encode(makePayload(this.clientId, Date.now()));
                const frame = new Uint8Array(4 + body.byteLength);
                new DataView(frame.buffer).setUint32(0, seq, false);
                frame.set(body, 4);

                const sendStart = performance.now();
                let timer: number | undefined;
                const arrival = new Promise<number>((resolve) => waiters.set(seq, resolve));
                const timeout = new Promise<'timeout'>((resolve) => {
                    timer = setTimeout(() => resolve('timeout'), DATAGRAM_RECV_TIMEOUT_MS);
                });

                try {
                    await writer.write(frame);
                } catch {
                    waiters.delete(seq);
                    clearTimeout(timer);
                    if (!stopSignal.aborted) stats.errors++;
                    break;
                }

                const result = await Promise.race([arrival, timeout, abortPromise]);
                clearTimeout(timer);
                if (result === 'abort') {
                    waiters.delete(seq);
                    break;
                }
                if (result === 'timeout') {
                    waiters.delete(seq);
                    stats.errors++;   // datagram lost (request or echo dropped)
                } else {
                    stats.rtts.push(result - sendStart);
                    stats.echoesOk++;
                }
            }
        } finally {
            stopSignal.removeEventListener('abort', onAbort);
            try { wt.close(); } catch { /* ignore */ }
            try { writer.releaseLock(); } catch { /* ignore */ }
            await receiveLoop.catch(() => { /* ignore */ });
        }

        return stats;
    }
}

// ============================================================================
// Client factory
// ============================================================================

function makeClient(protocol: Protocol, target: string, clientId: number, certHash?: ArrayBuffer): ProtocolClient {
    switch (protocol) {
        case 'ws':             return new WebSocketClient(target, clientId);
        case 'sse':            return new SseClient(target, clientId);
        case 'short-polling':  return new ShortPollingClient(target, clientId);
        case 'long-polling':   return new LongPollingClient(target, clientId);
        case 'webtransport':   return new WebTransportClient(target, clientId, certHash!);
        case 'webtransport-datagram': return new WebTransportDatagramClient(target, clientId, certHash!);
    }
}

// ============================================================================
// Percentile math from sorted samples.
// ============================================================================
//
// Sort once, index by ceil(p * n) - 1 (nearest-rank). For a thesis it's worth
// noting the percentile definition in the methods section; nearest-rank is
// the discrete percentile most commonly used in latency reporting.

function percentile(sorted: Float64Array, p: number): number {
    if (sorted.length === 0) return NaN;
    const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil(p * sorted.length) - 1));
    return sorted[idx];
}

function mergeRtts(buffers: RttBuffer[]): Float64Array {
    let total = 0;
    for (const b of buffers) total += b.length;
    const out = new Float64Array(total);
    let off = 0;
    for (const b of buffers) {
        out.set(b.data.subarray(0, b.length), off);
        off += b.length;
    }
    out.sort();
    return out;
}

// ============================================================================
// CSV output
// ============================================================================

const METRICS_HEADER = 'Timestamp,Profile,Runtime,ProtocolVariant,Protocol,Concurrency,DurationSec,PacketLossPct,DelayMs,Throughput,p50_ms,p95_ms,p99_ms,Errors,Overflows,MeanConnect_ms\n';

async function appendMetricsRow(metricsPath: string, row: string): Promise<void> {
    let needsHeader = false;
    try {
        await Deno.stat(metricsPath);
    } catch (e) {
        if (e instanceof Deno.errors.NotFound) needsHeader = true;
        else throw e;
    }
    const text = needsHeader ? METRICS_HEADER + row : row;
    await Deno.writeTextFile(metricsPath, text, { append: true });
}

async function writeRawRtts(rawPath: string, clientStats: ClientStats[]): Promise<void> {
    // Streamed write: one line per sample. For long runs this avoids holding
    // a giant string in memory.
    const file = await Deno.open(rawPath, { write: true, create: true, truncate: true });
    const encoder = new TextEncoder();
    try {
        await file.write(encoder.encode('client_id,rtt_ms\n'));
        for (let c = 0; c < clientStats.length; c++) {
            const buf = clientStats[c].rtts;
            // Buffer up to ~64KB before each write.
            let chunk = '';
            for (let i = 0; i < buf.length; i++) {
                chunk += `${c},${buf.data[i]}\n`;
                if (chunk.length >= 65536) {
                    await file.write(encoder.encode(chunk));
                    chunk = '';
                }
            }
            if (chunk.length > 0) await file.write(encoder.encode(chunk));
        }
    } finally {
        file.close();
    }
}

// ============================================================================
// Main
// ============================================================================

async function main(): Promise<void> {
    const args = parseArgs(Deno.args);

    // Under heavy packet loss, Deno's WebTransport surfaces handshake timeouts
    // via internal promises (wt.ready / wt.closed and others) whose rejections
    // can escape the per-client try/catch on a different microtask tick, landing
    // as a process-fatal "Uncaught (in promise)". A failed client is already
    // recorded as stats.errors and must NOT abort the other 49. Swallow ONLY
    // these timeout/WebTransport rejections here; anything else is re-thrown so
    // real bugs still crash loudly. This is pure robustness — it does not touch
    // the echo loop, pipeline depth, or stream handling.
    // Under packet loss the QUIC layer also tears connections down mid-handshake
    // and mid-run as PLAIN Error objects (name "Error"), not WebTransportError —
    // e.g. "reset by peer", "connection reset/closed/lost". Those slip past a
    // name === 'WebTransportError' check and crash the process, so match them by
    // message too. A genuine logic bug (TypeError/ReferenceError/…) won't contain
    // these connection-teardown phrases, so it still surfaces and crashes loudly.
    globalThis.addEventListener('unhandledrejection', (e: PromiseRejectionEvent) => {
        const r = e.reason;
        const name = r?.name ?? '';
        const msg = String(r?.message ?? r ?? '');
        if (
            name === 'WebTransportError' ||
            /timed out|reset by (peer|remote)|(connection|stream) (reset|closed|lost|aborted)|aborted by (peer|remote)/i.test(msg)
        ) {
            e.preventDefault();
        }
    });

    await Deno.mkdir(args.resultsDir, { recursive: true });

    console.log(`[load_generator] protocol=${args.protocol} target=${args.target} clients=${args.clients} duration=${args.duration}s`);

    let certHash: ArrayBuffer | undefined;
    if (args.protocol === 'webtransport' || args.protocol === 'webtransport-datagram') {
        const certPath = new URL('../servers/cert.pem', import.meta.url);
        const certPem = await Deno.readTextFile(certPath);
        certHash = await crypto.subtle.digest('SHA-256', decodePemToDer(certPem).buffer as ArrayBuffer);
    }

    const stopController = new AbortController();
    // Deno re-throws AbortError from abort() when fetch() calls hold the signal;
    // catch and discard it — the error surfaces correctly in each client's catch block.
    const stopAt = setTimeout(() => { try { stopController.abort(); } catch { /* expected */ } }, args.duration * 1000);

    const clientPromises: Promise<ClientStats>[] = [];
    for (let i = 0; i < args.clients; i++) {
        clientPromises.push(makeClient(args.protocol, args.target, i, certHash).run(stopController.signal));
    }

    const runStart = performance.now();
    const allStats = await Promise.all(clientPromises);
    const wallMs = performance.now() - runStart;
    clearTimeout(stopAt);

    // Aggregate.
    const merged = mergeRtts(allStats.map((s) => s.rtts));
    const totalOk = allStats.reduce((a, s) => a + s.echoesOk, 0);
    const totalErr = allStats.reduce((a, s) => a + s.errors, 0);
    const totalOverflows = allStats.reduce((a, s) => a + s.rtts.overflows, 0);
    const connectTimes = allStats.map((s) => s.connectTimeMs).filter((t) => t >= 0);

    const throughput = totalOk / (wallMs / 1000);
    const p50 = percentile(merged, 0.50);
    const p95 = percentile(merged, 0.95);
    const p99 = percentile(merged, 0.99);
    const meanConnect = connectTimes.length > 0
        ? connectTimes.reduce((a, b) => a + b, 0) / connectTimes.length
        : NaN;

    // Summary to stdout.
    console.log('');
    console.log('=== summary ===');
    console.log(`protocol         : ${args.protocol}`);
    console.log(`concurrency      : ${args.clients}`);
    console.log(`wall time (s)    : ${(wallMs / 1000).toFixed(3)}`);
    console.log(`echoes ok        : ${totalOk}`);
    console.log(`errors           : ${totalErr}`);
    console.log(`rtt samples      : ${merged.length}`);
    console.log(`buffer overflows : ${totalOverflows}`);
    console.log(`throughput (msg/s): ${throughput.toFixed(2)}`);
    console.log(`mean connect (ms): ${meanConnect.toFixed(3)}`);
    console.log(`p50 (ms)         : ${p50.toFixed(3)}`);
    console.log(`p95 (ms)         : ${p95.toFixed(3)}`);
    console.log(`p99 (ms)         : ${p99.toFixed(3)}`);

    // CSV output. metrics.csv lives at the parent of the per-run dir so it
    // aggregates across runs; raw rtts.csv lives inside the per-run dir.
    const metricsPath = `${args.resultsDir.replace(/\/+$/, '')}/../metrics.csv`;
    const rawPath = `${args.resultsDir.replace(/\/+$/, '')}/rtts.csv`;

    const row = [
        new Date().toISOString(),
        args.profile,           // self-describing dimensions (from harness env)
        args.runtime,
        args.protocolVariant,
        args.protocol,
        args.clients,
        args.duration,
        args.packetLossPct,     // numeric string or "" if unknown
        args.delayMs,           // numeric string or "" if unknown
        throughput.toFixed(3),
        p50.toFixed(4),
        p95.toFixed(4),
        p99.toFixed(4),
        totalErr,
        totalOverflows,
        // Empty cell (not the literal "NaN") when every client failed to
        // connect, so downstream pandas parses it as a missing value.
        Number.isNaN(meanConnect) ? '' : meanConnect.toFixed(4),
    ].join(',') + '\n';

    await appendMetricsRow(metricsPath, row);
    await writeRawRtts(rawPath, allStats);

    console.log('');
    console.log(`wrote summary row -> ${metricsPath}`);
    console.log(`wrote raw rtts    -> ${rawPath}`);
}

if (import.meta.main) {
    main().catch((err) => {
        console.error('[load_generator] fatal:', err);
        Deno.exit(1);
    });
}
