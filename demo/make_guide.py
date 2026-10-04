"""Builds the scratch narration (macOS `say`) and subtitles from narration.json.

    python3 demo/make_guide.py   → demo/out/guide.m4a, demo/out/ryoko-demo.srt

The scratch voice is only a timing guide for recording the real narration.
"""
import json, os, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
VO = os.path.join(OUT, "vo")
os.makedirs(VO, exist_ok=True)
lines = json.load(open(os.path.join(HERE, "narration.json")))

def duration(path):
    return float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path]))

def stamp(t):
    h, rem = divmod(t, 3600); m, s = divmod(rem, 60)
    return f"{int(h):02}:{int(m):02}:{int(s):02},{int(round((s % 1) * 1000)):03}"

inputs, filters, srt = [], [], []
for i, line in enumerate(lines):
    clip = os.path.join(VO, f"guide_{line['id']}.aiff")
    subprocess.run(["say", "-v", "Samantha", "-r", "168", "-o", clip, line["text"]], check=True)
    line["dur"] = duration(clip)
    inputs += ["-i", clip]
    ms = int(line["at"] * 1000)
    filters.append(f"[{i}]adelay={ms}|{ms}[a{i}]")
    srt.append(f"{i + 1}\n{stamp(line['at'])} --> {stamp(line['at'] + line['dur'])}\n{line['text']}\n")
    nxt = lines[i + 1]["at"] if i + 1 < len(lines) else 180
    flag = "  ⚠ overlaps next line" if line["at"] + line["dur"] > nxt else ""
    print(f"{line['id']} {line['at']:6.1f}s + {line['dur']:4.1f}s → {line['at'] + line['dur']:6.1f}s (next {nxt}){flag}")

mix = ";".join(filters) + ";" + "".join(f"[a{i}]" for i in range(len(lines))) + f"amix=inputs={len(lines)}:normalize=0,apad=whole_dur=180[out]"
subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *inputs, "-filter_complex", mix, "-map", "[out]", "-t", "180",
                "-c:a", "aac", "-b:a", "160k", os.path.join(OUT, "guide.m4a")], check=True)
open(os.path.join(OUT, "ryoko-demo.srt"), "w").write("\n".join(srt))
print("wrote out/guide.m4a and out/ryoko-demo.srt")
