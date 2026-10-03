#!/bin/zsh
# D2: build 16 kHz mono s16le PCM test clips with macOS `say` + ffmpeg.
# Output: spikes/soniox/out/audio/*.pcm (raw) and *.wav (for listening).
set -euo pipefail
cd "${0:A:h}"
A=out/audio
mkdir -p $A

say -v Tingting -o $A/zh.aiff "你好，我要一杯多肉葡萄，少糖。在这喝还是带走？"
say -v Kyoko    -o $A/ja.aiff "すみません、食券の買い方を教えてください。麺はかためでお願いします。"
say -v Samantha -o $A/en.aiff "Less sugar please, and I'll take it to go."

for n in zh ja en; do
  ffmpeg -loglevel error -y -i $A/$n.aiff -ar 16000 -ac 1 -c:a pcm_s16le $A/$n.wav
done
ffmpeg -loglevel error -y -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -c:a pcm_s16le $A/sil1.wav

# Conversations: en, 1 s silence, X, 1 s silence, en
for x in zh ja; do
  ffmpeg -loglevel error -y -i $A/en.wav -i $A/sil1.wav -i $A/$x.wav -i $A/sil1.wav -i $A/en.wav \
    -filter_complex '[0][1][2][3][4]concat=n=5:v=0:a=1' -ar 16000 -ac 1 -c:a pcm_s16le $A/conv_$x.wav
  # Noisy-hall approximation: low-volume pink noise under the conversation
  ffmpeg -loglevel error -y -i $A/conv_$x.wav \
    -f lavfi -i "anoisesrc=color=pink:amplitude=0.08:sample_rate=16000:seed=7" \
    -filter_complex '[0][1]amix=inputs=2:duration=first:normalize=0' -ar 16000 -ac 1 -c:a pcm_s16le $A/conv_${x}_noisy.wav
done

for f in $A/*.wav; do
  ffmpeg -loglevel error -y -i $f -f s16le -ar 16000 -ac 1 ${f:r}.pcm
done
ls -l $A
