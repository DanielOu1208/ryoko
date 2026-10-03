#!/bin/zsh
# D2: full Soniox run. Needs a valid SONIOX_API_KEY in server/.env (never printed).
# Output: out/runs/*.json (raw responses), out/results/*.json (analysis).
set -uo pipefail
cd "${0:A:h}"
[[ -f out/audio/conv_zh.pcm ]] || ./make-audio.sh
[[ -f out/audio/conv_zh_loud.pcm ]] || ./make-noise.sh

echo "== auth check"
node stream.mjs --file out/audio/en.pcm --pair zh --label en_zhpair || { echo "auth/stream failed; stopping"; exit 2; }

run() { # file pair label expect [vad]
  node stream.mjs --file out/audio/$1.pcm --pair $2 --label $3 && \
  node analyze.mjs $3 --vad out/audio/${5:-$1}.pcm --expect $4 > /dev/null && echo "  analysed $3"
}
echo "== zh <-> en"
run zh zh zh zh
run conv_zh zh conv_zh en,zh,en
run conv_zh_noisy zh conv_zh_noisy en,zh,en conv_zh
run conv_zh_loud zh conv_zh_loud en,zh,en conv_zh
echo "== ja <-> en"
run en ja en_japair en
run ja ja ja ja
run conv_ja ja conv_ja en,ja,en
run conv_ja_loud ja conv_ja_loud en,ja,en conv_ja
node analyze.mjs en_zhpair --expect en > /dev/null

echo "== temporary key (mint + use for one session)"
node stream.mjs --file out/audio/en.pcm --pair zh --label tempkey_en --temp-key

node summary.mjs
