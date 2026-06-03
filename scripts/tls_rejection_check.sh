#!/usr/bin/env bash
#
# Autonomous MITM-rejection check.
#
# Stands up a throwaway local HTTPS server with a self-signed certificate (an
# "attacker" the system does not trust), then runs OWATLSRejectionTests, which drives
# the real OWAClient against it and asserts the connection is rejected as
# `untrustedCertificate` before any credentials are sent — and that the reported leaf
# fingerprint matches the server's actual certificate.
#
# Touches nothing on the system: localhost only, temp files cleaned up on exit.
set -euo pipefail

TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# 1. Self-signed cert for 127.0.0.1 (SAN IP) — untrusted by the system store.
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 1 -nodes -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1

# 2. Expected leaf fingerprint = SHA-256 over the DER encoding, lowercase hex, no colons.
FP="$(openssl x509 -in "$TMP/cert.pem" -outform DER | openssl dgst -sha256 \
      | awk '{print $NF}' | tr 'A-F' 'a-f' | tr -d ':')"

# 3. Minimal HTTPS server on an ephemeral port; prints the chosen port.
cat > "$TMP/server.py" <<'PY'
import http.server, ssl, sys
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(sys.argv[1], sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
httpd = http.server.HTTPServer(('127.0.0.1', 0), H)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
print(httpd.server_address[1], flush=True)
httpd.serve_forever()
PY

python3 "$TMP/server.py" "$TMP/cert.pem" "$TMP/key.pem" > "$TMP/port.txt" 2>/dev/null &
SERVER_PID=$!

PORT=""
for _ in $(seq 1 50); do
  PORT="$(cat "$TMP/port.txt" 2>/dev/null || true)"
  [ -n "$PORT" ] && break
  sleep 0.1
done
[ -n "$PORT" ] || { echo "ERROR: HTTPS test server did not start"; exit 1; }

echo "Local self-signed HTTPS server: 127.0.0.1:$PORT"
echo "Expected leaf SHA-256: $FP"
echo

OWA_TEST_TLS_URL="https://127.0.0.1:$PORT" \
OWA_TEST_TLS_FINGERPRINT="$FP" \
  swift test --filter OWATLSRejectionTests 2>&1
