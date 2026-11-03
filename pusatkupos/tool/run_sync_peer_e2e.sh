#!/usr/bin/env bash
set -euo pipefail

APP="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$APP/.." && pwd)"
ENV_FILE="$ROOT/.env"

FLUTTER="${PUSATKU_FLUTTER:-}"
if [ -z "$FLUTTER" ]; then
  if command -v flutter >/dev/null 2>&1; then
    FLUTTER="flutter"
  elif [ -x "/c/Users/Administrator/flutter/bin/flutter" ]; then
    FLUTTER="/c/Users/Administrator/flutter/bin/flutter"
  else
    echo "Flutter tidak ditemukan. Set PUSATKU_FLUTTER." >&2
    exit 1
  fi
fi

RELAY_PORT="8120"
RELAY_TOKEN="${PUSATKU_RELAY_TOKEN:-}"
if [ -f "$ENV_FILE" ]; then
  value="$(grep -E '^RELAY_ENROLL_TOKEN=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
  [ -n "$value" ] && RELAY_TOKEN="$value"
  value="$(grep -E '^RELAY_PORT=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
  [ -n "$value" ] && RELAY_PORT="$value"
fi
RELAY_URL="${PUSATKU_RELAY_URL:-http://127.0.0.1:$RELAY_PORT}"
if [ -z "$RELAY_TOKEN" ]; then
  echo "RELAY_ENROLL_TOKEN tidak ditemukan di .env atau lingkungan." >&2
  exit 1
fi
if ! curl -fsS "$RELAY_URL/relay/health" >/dev/null; then
  echo "Relay tidak dapat dihubungi di $RELAY_URL." >&2
  exit 1
fi

BASE="$(mktemp -d "${TMPDIR:-/tmp}/pusatkupos_sync_e2e.XXXXXX")"
if command -v cygpath >/dev/null 2>&1; then
  BASE_WIN="$(cygpath -m "$BASE")"
else
  BASE_WIN="$BASE"
fi
SESSION="$BASE/session.json"
cat > "$SESSION" <<JSON
{"base_dir":"$BASE_WIN","relay_url":"$RELAY_URL","relay_token":"$RELAY_TOKEN","store_id":"utama"}
JSON

run_phase() {
  local phase="$1"
  echo "== Fase $phase =="
  (
    cd "$APP"
    "$FLUTTER" test test/sync_peer_test.dart \
      --dart-define=PEER_CONFIG="$SESSION" \
      --dart-define=PEER_PHASE="$phase" \
      --dart-define=PUSATKU_SECURE_DB=true
  )
}

run_phase init
run_phase A1
run_phase B1
run_phase A2
run_phase B2
run_phase A3
run_phase A4
run_phase B3
run_phase M1
run_phase E1
run_phase A6
run_phase E2
run_phase R1
run_phase V1
run_phase A7
run_phase V2

echo "== Hasil JSON =="
for file in "$BASE"/*.json; do
  [ "$(basename "$file")" = "session.json" ] && continue
  echo "-- $(basename "$file")"
  cat "$file"
  echo
done

echo "SEMUA FASE MULTI-DEVICE LULUS ($BASE)"
