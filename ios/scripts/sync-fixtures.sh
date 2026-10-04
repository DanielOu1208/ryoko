#!/bin/sh
# Copies the contract examples the app bundles from contracts/examples/, and the
# tables it reads at runtime from contracts/tables/, into
# ios/Ryoko/App/Core/Fixtures/. Everything in that synced folder is copied into
# the app bundle as a resource: FixtureRyokoAPI reads the examples, and the
# allergy and taxi cards read allergy-templates.json (design §4.5, §4.6).
#
#   ios/scripts/sync-fixtures.sh          copy (only files that changed)
#   ios/scripts/sync-fixtures.sh --check  exit 1 if any copy is missing or stale
#
# Keep FILES in step with `FixtureFile` in ios/Ryoko/App/Core/Fixtures.swift.
# error.invalid-request.request.json is left out on purpose: it's invalid by design.
# TABLES are read by name (`AllergyTemplates` in ios/Ryoko/Show/).
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/contracts/examples"
TABLE_SRC="$ROOT/contracts/tables"
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
translate.request.json
translate.response.json
translate.tokyo.request.json
translate.tokyo.response.json
soniox-key.response.json
mimo-message.request.json
mimo-models.response.json
trip-events.request.json
trip-events.response.json
mimo.sse.txt
mimo.zh-hans.sse.txt
error.invalid-request.response.json
error.session-busy.response.json
"

TABLES="
allergy-templates.json
categories.json
"

mode="${1:-copy}"
stale=0
copied=0
mkdir -p "$DEST"

# sync_one <source dir> <file>
sync_one() {
  if [ ! -f "$1/$2" ]; then
    echo "missing in ${1#"$ROOT"/}: $2" >&2
    exit 1
  fi
  if cmp -s "$1/$2" "$DEST/$2"; then
    return 0
  fi
  if [ "$mode" = "--check" ]; then
    echo "stale: Core/Fixtures/$2" >&2
    stale=1
  else
    cp "$1/$2" "$DEST/$2"
    echo "copied $2"
    copied=$((copied + 1))
  fi
}

for f in $FILES; do
  sync_one "$SRC" "$f"
done
for f in $TABLES; do
  sync_one "$TABLE_SRC" "$f"
done

# Anything in Fixtures/ that isn't in the list is left over from an old sync.
for path in "$DEST"/*; do
  [ -e "$path" ] || continue
  name="$(basename "$path")"
  case " $(echo $FILES $TABLES) " in
    *" $name "*) ;;
    *) echo "not in the fixture list (remove it or add it to FILES): Core/Fixtures/$name" >&2; stale=1 ;;
  esac
done

if [ "$mode" = "--check" ]; then
  [ "$stale" -eq 0 ] && echo "Fixtures are in sync with contracts/examples and contracts/tables."
  exit "$stale"
fi
echo "Synced: $copied file(s) updated in ios/Ryoko/App/Core/Fixtures."
exit "$stale"
