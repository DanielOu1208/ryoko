#!/usr/bin/env bash
# Asks for API keys (input hidden) and writes them into the gitignored config
# files: server/.env, plus ios/Config/Secrets.xcconfig for the Soniox key.
# Press Enter on a prompt to leave that key unchanged. Never prints a key.
#
#   bash scripts/set-keys.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/server/.env"
XC_FILE="$ROOT/ios/Config/Secrets.xcconfig"

[ -f "$ENV_FILE" ] || cp "$ROOT/server/.env.example" "$ENV_FILE"
[ -f "$XC_FILE" ] || cp "$ROOT/ios/Config/Secrets.example.xcconfig" "$XC_FILE"

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

ask() {
  local prompt="$1" value
  read -r -s -p "$prompt (Enter to skip): " value
  echo >&2
  printf '%s' "$value"
}

soniox="$(ask "Soniox API key")"
if [ -n "$soniox" ]; then
  set_key "$ENV_FILE" SONIOX_API_KEY "$soniox" "="
  set_key "$XC_FILE" SONIOX_API_KEY "$soniox" " = "
  echo "Soniox key saved (${#soniox} chars) to server/.env and ios/Config/Secrets.xcconfig"
fi

exa="$(ask "Exa API key")"
if [ -n "$exa" ]; then
  set_key "$ENV_FILE" EXA_API_KEY "$exa" "="
  echo "Exa key saved (${#exa} chars) to server/.env"
fi

chmod 600 "$ENV_FILE" "$XC_FILE"
cd "$ROOT"
git check-ignore -q server/.env && git check-ignore -q ios/Config/Secrets.xcconfig \
  && echo "Both files are gitignored." \
  || { echo "WARNING: a secrets file is NOT gitignored"; exit 1; }
