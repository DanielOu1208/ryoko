#!/bin/sh
# D1 MapKit spike. Builds a plain CLI (no app bundle needed on macOS 27) and writes
# raw output to out/, which is gitignored. Apple Maps terms: never commit out/.
set -e
cd "$(dirname "$0")"
mkdir -p out
swiftc -O -o out/mapkit-spike main.swift -framework MapKit -framework CoreLocation
./out/mapkit-spike --probe          > out/en.txt 2>&1
./out/mapkit-spike -AppleLanguages '(zh-Hans)' > out/zh.txt 2>&1
./out/mapkit-spike -AppleLanguages '(ja)'      > out/ja.txt 2>&1
./out/mapkit-spike --switch     ; defaults delete mapkit-spike 2>/dev/null || true
./out/mapkit-spike --set-before ; defaults delete mapkit-spike 2>/dev/null || true
for c in taipei hk; do
  ./out/mapkit-spike --city $c > out/$c-en.txt 2>&1
  ./out/mapkit-spike --city $c -AppleLanguages '(zh-Hant)' > out/$c-zh.txt 2>&1
done
echo "Wrote out/{en,zh,ja,taipei-en,taipei-zh,hk-en,hk-zh}.txt"
