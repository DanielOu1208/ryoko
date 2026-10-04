"""Records the demo's three takes on the demo simulator.

    python3 demo/capture/scenes.py map|translate|mimo|all

Each take is one continuous recording of the real app driven by real touches
(see device.py), saved to demo/out/raw/<take>.mp4 with <take>.events.json:
seconds from the recording's start for each step, for cutting in the edit.
Needs the demo server (`PORT=8795 node src/index.ts` in server/), the demo
profile installed (prep.sh), and Xcode open.
"""
import json
import os
import sys
import time

from device import Device, Recorder, launch, key_taps

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "out", "raw")


class Take:
    def __init__(self, name):
        self.name = name
        self.events = []
        self.device = Device()

    def mark(self, label):
        self.events.append({"t": round(time.time() - self.rec.started, 2), "label": label})
        print(f"  {self.events[-1]['t']:6.1f}s  {label}", flush=True)

    def run(self, command, label=None):
        if label:
            self.mark(label)
        return self.device.run(command)

    def __enter__(self):
        self.device.run("")  # session up before recording
        self.rec = Recorder(os.path.join(OUT, f"{self.name}.mp4")).__enter__()
        return self

    def __exit__(self, *exc):
        self.mark("end")
        self.rec.__exit__(*exc)
        json.dump(self.events, open(os.path.join(OUT, f"{self.name}.events.json"), "w"), indent=1)


def take_map():
    """Map home → picks → search 7-Eleven → its phrases → Show → Me → Nara Park tips."""
    with Take("map") as take:
        d = take.device
        take.mark("launch")
        launch("-RyokoInitialTab", "map", clock="2026-10-10T09:40:50+09:00")
        take.run("w 9", "picks arriving")
        take.run("mt [200 740] 1.8 [200 520] 0.6 w 2.2", "scroll picks")
        take.run("mt [200 520] 1.4 [200 740] 0.5 w 1.2", "scroll back")
        take.run("t 207 90 w 1.2", "tap search")
        take.run(key_taps("7-eleven") + " w 1.6", "typing 7-eleven")
        d.run("")
        result = d.find("7-Eleven, 川井ビル") or d.find("7-Eleven")
        take.run(f"t {result['x']} {result['y']} w 6.5", "open 7-Eleven card")
        take.run("mt [200 700] 2.0 [200 330] 0.7 w 3.5", "scroll to phrases")
        take.run("mt [200 640] 1.4 [200 440] 0.6 w 2.5", "scroll to allergy phrase")
        d.run("")
        shows = [e for e in d.elements(("Button",)) if e["label"] == "Show" and e["y"] < 770]
        show = shows[-1]
        take.run(f"t {show['x']} {show['y']} w 3.5", f"show mode ({len(shows)} visible)")
        take.run("t 58 84 w 3", "flip")
        take.run("t 349 84 w 1.8", "done")
        take.run("t 329.5 822 w 3.5", "me tab")
        take.run("mt [200 700] 2.2 [200 330] 0.7 w 4", "scroll me")
        take.run("mt [200 330] 1.6 [200 700] 0.6 w 1.5", "scroll me back")
        take.run("t 158.2 822 w 1.8", "map tab")
        take.run("t 52.7 204 w 2.2", "back to list")
        d.run("")
        park = d.find("Nara Park, 奈良公園")
        take.run(f"t {park['x']} {park['y']} w 6.5", "open Nara Park card")
        take.run("mt [200 720] 2.0 [200 370] 0.7 w 1.2", "scroll card")
        take.run("mt [200 720] 1.8 [200 400] 0.7 w 6", "tips")


def take_translate():
    """Translate: a coffee order in Chinese (canned stream), flipped face to face midway."""
    with Take("translate") as take:
        take.mark("launch")
        launch("-RyokoInitialTab", "translate", "-RyokoTranslateSource", "canned",
               "-RyokoTranslateCannedScript", "coffee", "-RyokoTranslateOther", "zh-Hans",
               "-RyokoTranslateCannedPace", "2.4")
        take.run("w 3.5", "idle")
        take.run("t 201 737 w 15.3", "tap mic")
        d = take.device
        d.run("")
        layout = d.find("Layout")
        take.run(f"t {layout['x']} {layout['y']} w 16", "face to face")
        take.run("w 2", "hold")


def take_mimo():
    """Mimo: type a question on the keyboard, send, read the plan, Show on map."""
    with Take("mimo") as take:
        d = take.device
        take.mark("launch")
        launch("-RyokoInitialTab", "mimo", "-RyokoMimoNewChat", "1", clock="2026-10-10T09:40:50+09:00")
        take.run("w 3.5", "idle")
        take.run("t 160 754 w 1.2", "tap composer")
        take.run(key_taps("Help me plan a 3-hour tour nearby") + " w 1.0", "typing question")
        send = d.find("Send", above=800)
        take.run(f"t {send['x']} {send['y']} w 1.0", "send")
        take.run("t 200 330 f 200 560 0.25 w 11", "dismiss keyboard, reply streams")
        take.run("mt [200 260] 1.6 [200 600] 0.6 w 2.5", "scroll up to the start")
        take.run("mt [200 600] 1.6 [200 260] 0.6 w 2", "scroll back down")
        d.run("")
        take.run(f"t {d.find('Show on map', below=60)['x']} {d.find('Show on map', below=60)['y']} w 6", "show on map")


def take_park():
    """Map list → Nara Park (a Mimo pick) → its card, scrolled to the tips."""
    with Take("park") as take:
        d = take.device
        take.mark("launch")
        launch("-RyokoInitialTab", "map", clock="2026-10-10T09:40:50+09:00")
        take.run("w 12", "picks")
        d.run("")
        park = d.find("Nara Park, 奈良公園")
        take.run(f"t {park['x']} {park['y']} w 6.5", "open Nara Park card")
        take.run("mt [200 720] 1.6 [200 370] 0.6 w 1.0", "scroll 1")
        take.run("mt [200 720] 1.6 [200 370] 0.6 w 1.0", "scroll 2")
        take.run("mt [200 720] 1.6 [200 400] 0.6 w 0.8", "scroll 3")
        take.run("mt [200 700] 1.4 [200 450] 0.6 w 6", "tips")


TAKES = {"map": take_map, "park": take_park, "translate": take_translate, "mimo": take_mimo}

if __name__ == "__main__":
    names = list(TAKES) if sys.argv[1:] == ["all"] else sys.argv[1:]
    for name in names:
        print(f"== {name}", flush=True)
        TAKES[name]()
