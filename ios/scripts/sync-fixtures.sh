#!/bin/sh
# Copies the contract examples the app bundles from contracts/examples/ into
# ios/Ryoko/App/Core/Fixtures/. Everything in that synced folder is copied into
# the app bundle as a resource, which is what FixtureRyokoAPI reads.
#
#   ios/scripts/sync-fixtures.sh          copy (only files that changed)
#   ios/scripts/sync-fixtures.sh --check  exit 1 if any copy is missing or stale
#
# Keep FILES in step with `FixtureFile` in ios/Ryoko/App/Core/Fixtures.swift.
# error.invalid-request.request.json is left out on purpose: it's invalid by design.
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/contracts/examples"
DEST="$ROOT/ios/Ryoko/App/Core/Fixtures"

FILES="
profile.seed.json
situation.shanghai-cafe.json
situation.tokyo-ramen.json
place-card.request.json
place-card.response.json
place-card.tokyo.request.json
place-card.tokyo.response.json
discover.request.json
discover.response.json
discover.tokyo.request.json
discover.tokyo.response.json
allergy-card.request.json
allergy-card.response.json
allergy-card.zh-hans.request.json
allergy-card.zh-hans.response.json
mimo-message.request.json
mimo.sse.txt
mimo.zh-hans.sse.txt
error.invalid-request.response.json
error.session-busy.response.json
"

mode="${1:-copy}"
stale=0
copied=0
mkdir -p "$DEST"

for f in $FILES; do
  if [ ! -f "$SRC/$f" ]; then
    echo "missing in contracts/examples: $f" >&2
    exit 1
  fi
  if cmp -s "$SRC/$f" "$DEST/$f"; then
    continue
  fi
  if [ "$mode" = "--check" ]; then
    echo "stale: Core/Fixtures/$f" >&2
    stale=1
  else
    cp "$SRC/$f" "$DEST/$f"
    echo "copied $f"
    copied=$((copied + 1))
  fi
done

# Anything in Fixtures/ that isn't in the list is left over from an old sync.
for path in "$DEST"/*; do
  [ -e "$path" ] || continue
  name="$(basename "$path")"
  case " $(echo $FILES) " in
    *" $name "*) ;;
    *) echo "not in the fixture list (remove it or add it to FILES): Core/Fixtures/$name" >&2; stale=1 ;;
  esac
done

if [ "$mode" = "--check" ]; then
  [ "$stale" -eq 0 ] && echo "Fixtures are in sync with contracts/examples."
  exit "$stale"
fi
echo "Synced: $copied file(s) updated in ios/Ryoko/App/Core/Fixtures."
exit "$stale"
