#!/bin/sh
# Builds and runs a Mac command-line check of the Swift contract mirrors in
# ios/Shared/ and the Foundation-only parts of ios/Ryoko/App/Core/:
# - every contracts/examples file (and its bundled copy) decodes and encodes back
#   to the same JSON,
# - LangCode and CategorySlug match contracts/tables/,
# - the SSE line reader, the situation clock and the API error mapping behave.
#
#   ios/scripts/check-contracts.sh          offline checks only
#   ios/scripts/check-contracts.sh --live   also calls the server at
#                                           RYOKO_LIVE_BASE_URL (default
#                                           http://127.0.0.1:8792) with APP_TOKEN
#                                           read from server/.env
#
# Run it after any change to contracts/ or ios/Shared/. Needs Xcode's swiftc.
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/ios/.build/contract-check"
mkdir -p "$OUT"

CORE="$ROOT/ios/Ryoko/App/Core"
xcrun swiftc \
  -swift-version 6 \
  -default-isolation MainActor \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature MemberImportVisibility \
  -D DEBUG \
  -module-name RyokoContractCheck \
  -o "$OUT/contract-check" \
  "$ROOT"/ios/Shared/Contracts/*.swift \
  "$ROOT/ios/Shared/LangCode.swift" \
  "$ROOT/ios/Shared/PlaceCategory.swift" \
  "$CORE/RyokoLog.swift" \
  "$CORE/RyokoAPI.swift" \
  "$CORE/RyokoAPIConfiguration.swift" \
  "$CORE/LiveRyokoAPI.swift" \
  "$CORE/SSELineReader.swift" \
  "$CORE/Fixtures.swift" \
  "$CORE/FixtureRyokoAPI.swift" \
  "$CORE/FixtureSelfCheck.swift" \
  "$ROOT/ios/scripts/ContractCheck/main.swift"

if [ "${1:-}" = "--live" ]; then
  # Read the token at runtime only; never print it.
  if [ -z "${RYOKO_APP_TOKEN:-}" ] && [ -f "$ROOT/server/.env" ]; then
    RYOKO_APP_TOKEN="$(grep -E '^APP_TOKEN=' "$ROOT/server/.env" | head -n 1 | cut -d= -f2- | tr -d '"'"'"' ')"
  fi
  export RYOKO_APP_TOKEN="${RYOKO_APP_TOKEN:-}"
  export RYOKO_LIVE_BASE_URL="${RYOKO_LIVE_BASE_URL:-http://127.0.0.1:8792}"
  if [ -z "$RYOKO_APP_TOKEN" ]; then
    echo "No APP_TOKEN in server/.env or RYOKO_APP_TOKEN; can't run the live check." >&2
    exit 1
  fi
fi

RYOKO_ROOT="$ROOT" "$OUT/contract-check"
