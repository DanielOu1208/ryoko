#!/bin/zsh
# Louder pink-noise variant (~10 dB SNR) of the conversations.
set -euo pipefail
cd "${0:A:h}"
A=out/audio
for x in zh ja; do
  ffmpeg -loglevel error -y -i $A/conv_$x.wav \
    -f lavfi -i "anoisesrc=color=pink:amplitude=0.2:sample_rate=16000:seed=11" \
    -filter_complex '[0][1]amix=inputs=2:duration=first:normalize=0' -ar 16000 -ac 1 -c:a pcm_s16le $A/conv_${x}_loud.wav
  ffmpeg -loglevel error -y -i $A/conv_${x}_loud.wav -f s16le -ar 16000 -ac 1 $A/conv_${x}_loud.pcm
done
