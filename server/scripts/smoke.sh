#!/usr/bin/env bash
# Smoke test against a running server (default http://127.0.0.1:8792), using the
# contracts examples. The token is read from server/.env and passed to curl on
# stdin, so it never appears in argv or in the output.
#
#   MODEL=faux pnpm --dir server start      # in another terminal
#   server/scripts/smoke.sh [base-url]
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
examples="$here/../contracts/examples"
base="${1:-http://127.0.0.1:8792}"

token="$(node -e 'const {parseEnv} = require("node:util"); const fs = require("node:fs"); process.stdout.write(parseEnv(fs.readFileSync(process.argv[1], "utf8")).APP_TOKEN ?? "")' "$here/.env")"
if [[ -z "$token" ]]; then echo "APP_TOKEN is missing from server/.env" >&2; exit 1; fi

# curl with the auth header from stdin. Prints "<status> <time>s" then the body.
authed() {
  printf 'Authorization: Bearer %s\n' "$token" | curl -sS -H @- -H 'Content-Type: application/json' \
    -H 'X-Install-Id: smoke-test' -H 'X-Client-Version: smoke' "$@"
}

echo "== GET /healthz (no auth)"
curl -sS -w '  -> %{http_code}\n' "$base/healthz"

echo "== POST /v1/place-card without a token"
curl -sS -X POST -w '  -> %{http_code}\n' "$base/v1/place-card" --data-binary '{}'

for pair in "place-card:place-card.request.json" "place-card:place-card.tokyo.request.json" \
            "discover:discover.request.json" "allergy-card:allergy-card.request.json"; do
  endpoint="${pair%%:*}"; file="${pair#*:}"
  echo "== POST /v1/$endpoint ($file)"
  out="$(authed -X POST "$base/v1/$endpoint" --data-binary "@$examples/$file" -w '\n%{http_code}')"
  status="${out##*$'\n'}"; body="${out%$'\n'*}"
  echo "  -> $status  $(jq -c 'if .error then .error else {language, phrases: (.phrases | length?), places: (.places | length?), items: (.items | length?), generatedAt} | with_entries(select(.value != null and .value != 0)) end' <<<"$body")"
done

echo "== POST /v1/place-card with an invalid body"
authed -X POST "$base/v1/place-card" --data-binary "@$examples/error.invalid-request.request.json" -w '  -> %{http_code}\n'

echo "== POST /v1/sessions/smoke-session/messages (SSE, timestamps in ms since start)"
start="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
authed -N -X POST "$base/v1/sessions/smoke-session/messages" --data-binary "@$examples/mimo-message.request.json" |
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    now="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')"
    printf '%6d  %s\n' "$((now - start))" "${line:0:110}"
  done
