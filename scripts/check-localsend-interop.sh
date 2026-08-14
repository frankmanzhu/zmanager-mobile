#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${LOCALSEND_HOST:-}" ]]; then
  echo "Set LOCALSEND_HOST to an official LocalSend peer hostname or IP." >&2
  exit 2
fi

PORT="${LOCALSEND_PORT:-53317}"
URL="https://${LOCALSEND_HOST}:${PORT}/api/localsend/v2/register"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BODY="$TMP_DIR/request.json"
RESPONSE="$TMP_DIR/response.json"
CERT="$TMP_DIR/certificate.der"

cat > "$BODY" <<'JSON'
{"alias":"ZManager Mobile","version":"2.0","deviceModel":"mobile","deviceType":"mobile","fingerprint":"zmanager-mobile-interop-probe","port":53317,"protocol":"https","download":false,"announce":false}
JSON

curl --fail --silent --show-error --max-time 5 --insecure \
  -X POST "$URL" \
  -H 'Content-Type: application/json' \
  --data-binary "@$BODY" > "$RESPONSE"

openssl s_client -connect "${LOCALSEND_HOST}:${PORT}" \
  -servername "$LOCALSEND_HOST" -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform der > "$CERT"

CERT_FINGERPRINT="$(shasum -a 256 "$CERT" | awk '{print toupper($1)}')"
python3 - "$RESPONSE" "$CERT_FINGERPRINT" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    response = json.load(handle)

required = ("alias", "version", "deviceModel", "deviceType", "fingerprint", "download")
missing = [key for key in required if key not in response]
if missing:
    raise SystemExit(f"LocalSend registration response is missing: {', '.join(missing)}")

fingerprint = re.sub(r"[^0-9A-Fa-f]", "", str(response["fingerprint"])).upper()
if fingerprint != sys.argv[2]:
    raise SystemExit("LocalSend HTTPS certificate fingerprint does not match registration fingerprint")

print(f"LocalSend registration OK: {response['alias']} {response['version']} HTTPS fingerprint {fingerprint}")
PY
