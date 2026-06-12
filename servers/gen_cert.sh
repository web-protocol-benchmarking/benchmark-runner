#!/usr/bin/env bash
#
# gen_cert.sh — (Re)generate the self-signed TLS cert + key used by every
# protocol server (WebTransport over QUIC, plus the wss:// / https:// servers).
#
# Produces a P-256 ECDSA self-signed cert with a <=14-day validity window —
# WebTransport's serverCertificateHashes requires the validity span be <=14 days,
# so re-run this before it lapses (the WS/SSE/polling paths tolerate any age
# because the Deno client connects with --unsafely-ignore-certificate-errors).
# The SAN covers the network-namespace IPs the harness binds to.
#
# The cert.pem/key.pem outputs are gitignored (servers/*.pem); only this script
# is committed, so the cert is reproducible on any machine.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout key.pem -out cert.pem -nodes -days 14 \
  -subj "/CN=benchmark" \
  -addext "subjectAltName=IP:10.0.0.1,IP:10.0.0.2,IP:127.0.0.1"

echo "regenerated $(pwd)/cert.pem + key.pem — valid 14 days; re-run before then."
