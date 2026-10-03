#!/usr/bin/env bash
# Saves API keys into the gitignored config files without ever printing them:
# server/.env, plus ios/Config/Secrets.xcconfig for the Soniox key.
#
# Easiest: copy the key, then run (works anywhere, including Claude Code's `!`):
#   bash scripts/set-keys.sh soniox      # reads the Soniox key from the clipboard
#   bash scripts/set-keys.sh exa         # reads the Exa key from the clipboard
#
# Soniox keys are checked against the Soniox API before saving.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/server/.env"
XC_FILE="$ROOT/ios/Config/Secrets.xcconfig"

usage() {
  echo "Usage: copy the key to the clipboard, then run one of:"
  echo "  bash scripts/set-keys.sh soniox"
  echo "  bash scripts/set-keys.sh exa"
  exit 1
}

which="${1:-}"
[ "$which" = "soniox" ] || [ "$which" = "exa" ] || usage

[ -f "$ENV_FILE" ] || cp "$ROOT/server/.env.example" "$ENV_FILE"
[ -f "$XC_FILE" ] || cp "$ROOT/ios/Config/Secrets.example.xcconfig" "$XC_FILE"

# Read the clipboard and trim whitespace, newlines and stray quotes.
key="$(pbpaste 2>/dev/null | tr -d '\r\n\t ' | sed -e 's/^["'\'']//' -e 's/["'\'']$//')"
if [ -z "$key" ]; then
  echo "The clipboard is empty. Copy the $which key first, then run this again."
  exit 1
fi

# set_key FILE KEY VALUE SEPARATOR: replace the KEY line, or append it.
set_key() {
  FILE="$1" KEY="$2" VAL="$3" SEP="$4" python3 - <<'PY'
import os, re
path, key, val, sep = (os.environ[k] for k in ("FILE", "KEY", "VAL", "SEP"))
text = open(path, encoding="utf-8").read()
line = f"{key}{sep}{val}"
pattern = re.compile(rf"^{re.escape(key)}\s*=.*$", re.M)
text = pattern.sub(lambda _: line, text, count=1) if pattern.search(text) else text.rstrip("\n") + "\n" + line + "\n"
open(path, "w", encoding="utf-8").write(text)
PY
}

case "$which" in
  soniox)
    case "$key" in
      *.*.*) echo "Note: this looks like a temporary or session token (it has dots). Console API keys usually don't." ;;
    esac
    status="$(curl -s -o /dev/null -w '%{http_code}' https://api.soniox.com/v1/models -H "Authorization: Bearer $key")"
    if [ "$status" != "200" ]; then
      echo "Soniox rejected this key (HTTP $status). Nothing was saved."
      echo "Create a key at https://console.soniox.com (your project, then API Keys), copy it, and run this again."
      exit 1
    fi
    set_key "$ENV_FILE" SONIOX_API_KEY "$key" "="
    set_key "$XC_FILE" SONIOX_API_KEY "$key" " = "
    echo "Soniox key works (HTTP 200) and was saved (${#key} chars) to server/.env and ios/Config/Secrets.xcconfig."
    ;;
  exa)
    status="$(curl -s -o /dev/null -w '%{http_code}' -X POST https://api.exa.ai/search -H "x-api-key: $key" -H 'content-type: application/json' -d '{"query":"test","numResults":1}')"
    if [ "$status" != "200" ]; then
      echo "Exa rejected this key (HTTP $status). Nothing was saved."
      exit 1
    fi
    set_key "$ENV_FILE" EXA_API_KEY "$key" "="
    echo "Exa key works (HTTP 200) and was saved (${#key} chars) to server/.env."
    ;;
esac

chmod 600 "$ENV_FILE" "$XC_FILE"
# Clear the clipboard so the key isn't left there.
printf '' | pbcopy
cd "$ROOT"
if git check-ignore -q server/.env && git check-ignore -q ios/Config/Secrets.xcconfig; then
  echo "Both files are gitignored. The clipboard was cleared."
else
  echo "WARNING: a secrets file is NOT gitignored."
  exit 1
fi
