"""Drives the demo simulator through Xcode 27's agent bridge (`xcrun mcpbridge`).

Xcode's `DeviceInteractionSynthesize` tool sends real touches to a simulator
(tap, swipe, multi-touch, typing) and returns a screenshot and the UI
hierarchy. Its command grammar is in Xcode's `device-interaction` skill
(`xcrun mcpbridge run-agent skills export <dir>`):

    t x y [hold]            tap          t x1 y1 f x2 y2 [dur]   swipe
    mt [x y] dur [x y] dur  drag/fingers  sender keyboard kbd <text>  type (last)
    w seconds               wait         Commands chain in one string.

The first call asks for approval in Xcode (open a project through the bridge).
Positions are in points, from the hierarchy's `hitPoint`s.
"""
import json
import os
import select
import signal
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
UDID = os.environ.get("RYOKO_DEMO_UDID", "303168FE-D5C4-4084-80F2-92D31A987784")
BUNDLE = "com.danielou.ryoko"
# One Xcode tool session for every bridge process, so the approval sticks.
XCODE_SESSION = "6F1C2A9E-1D7B-4C1E-9A3E-2B8D5E7F0A11"
KEYFILE = os.path.join(HERE, "..", "out", "interaction.key")


class Bridge:
    """A JSON-RPC client for `xcrun mcpbridge` (MCP over stdio)."""

    def __init__(self):
        env = {**os.environ, "MCP_XCODE_SESSION_ID": XCODE_SESSION}
        self.p = subprocess.Popen(["xcrun", "mcpbridge"], env=env, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.i = 0
        self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "ryoko-demo", "version": "1"}})
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _send(self, message):
        self.p.stdin.write(json.dumps(message) + "\n")
        self.p.stdin.flush()

    def call(self, method, params, timeout=240):
        self.i += 1
        my_id = self.i
        self._send({"jsonrpc": "2.0", "id": my_id, "method": method, "params": params})
        end = time.time() + timeout
        while time.time() < end:
            ready, _, _ = select.select([self.p.stdout], [], [], 0.5)
            if ready:
                line = self.p.stdout.readline()
                if not line:
                    raise RuntimeError("mcpbridge closed")
                message = json.loads(line)
                if message.get("id") == my_id:
                    return message
        raise TimeoutError(method)

    def tool(self, name, arguments, timeout=240):
        result = self.call("tools/call", {"name": name, "arguments": arguments}, timeout).get("result", {})
        return result.get("structuredContent") or result


class Device:
    """Touches on the demo simulator, plus the hierarchy after each command."""

    def __init__(self):
        self.bridge = Bridge()
        self.key = open(KEYFILE).read().strip() if os.path.exists(KEYFILE) else None
        self.last = None

    def _start_session(self):
        ident = "Ryoko Demo " + time.strftime("%H%M%S")
        result = self.bridge.tool("DeviceInteractionStartSession",
                                  {"deviceIdentifier": UDID, "sessionIdentifier": ident})
        self.key = result["interactionSessionKey"]
        os.makedirs(os.path.dirname(KEYFILE), exist_ok=True)
        open(KEYFILE, "w").write(self.key)

    def run(self, command=""):
        """Runs a command chain; returns the state captured after it."""
        for attempt in range(2):
            if not self.key:
                self._start_session()
            arguments = {"interactSessionKey": self.key}
            if command:
                arguments["interactionCommand"] = command
            result = self.bridge.tool("DeviceInteractionSynthesize", arguments)
            if "Session not found" in json.dumps(result) and attempt == 0:
                self.key = None
                continue
            break
        if "hierarchyPath" not in result:
            raise RuntimeError(f"{command!r}: {json.dumps(result)[:400]}")
        self.last = result
        return result

    # Hierarchy lookups on the last capture.

    def elements(self, kinds=("Button", "StaticText", "Cell", "TextField", "Key")):
        out = []
        for line in open(self.last["hierarchyPath"]):
            s = line.strip()
            kind = s.split(",")[0]
            if kind in kinds and "label: '" in s and "hitPoint: {" in s:
                label = s.split("label: '", 1)[1].rsplit("', hitPoint", 1)[0].split("', ")[0]
                x, y = s.split("hitPoint: {", 1)[1].split("}")[0].split(", ")
                out.append({"kind": kind, "label": label, "x": float(x), "y": float(y), "line": s})
        return out

    def find(self, prefix, kinds=("Button",), below=0, above=780):
        """The first element whose label starts with `prefix`, on screen above the tab bar."""
        for e in self.elements(kinds):
            if e["label"].startswith(prefix) and below < e["y"] < above:
                return e
        return None

    def tap(self, prefix, wait=1.0, kinds=("Button",), refresh=True):
        if refresh:
            self.run("")
        e = self.find(prefix, kinds)
        if not e:
            raise RuntimeError(f"no {prefix!r} on screen")
        return self.run(f"t {e['x']} {e['y']} w {wait}")


class Recorder:
    """`simctl io recordVideo` for one scene: start, then stop with SIGINT."""

    def __init__(self, path):
        self.path = path

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.p = subprocess.Popen(["xcrun", "simctl", "io", UDID, "recordVideo", "--codec=h264", "--force", self.path],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        end = time.time() + 20
        while time.time() < end:
            ready, _, _ = select.select([self.p.stderr], [], [], 0.5)
            if ready and "Recording started" in self.p.stderr.readline():
                self.started = time.time()
                return self
        raise RuntimeError("recording didn't start")

    def __exit__(self, *exc):
        self.p.send_signal(signal.SIGINT)
        self.p.wait(timeout=60)


def launch(*args, clock="2026-10-10T09:40:40+09:00"):
    """Relaunches Ryoko in the Nara demo setup, plus scene arguments."""
    base = ["-RyokoAPIMode", "live", "-RyokoAgentBaseURLOverride", os.environ.get("RYOKO_DEMO_SERVER", "http://127.0.0.1:8795"),
            "-RyokoDemo", "nara", "-RyokoClockStart", clock]
    subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", UDID, BUNDLE, *base, *args],
                   check=True, stdout=subprocess.DEVNULL)


# The on-screen keyboard (letters and numbers layers), for typing that shows key presses.
KEYS = json.load(open(os.path.join(HERE, "keyboard.json")))


def key_taps(text, hold=0.04, gap=0.06):
    """A command chain tapping `text` on the on-screen keyboard (starts on letters).
    Uppercase letters rely on auto-capitalization; the bridge takes about a
    second per tap, so speed this part up in the edit."""
    letters, numbers = KEYS["letters"], KEYS["numbers"]
    taps, layer = [], "letters"

    def tap(point):
        taps.append(f"t {point.replace(',', '')} {hold} w {gap}")

    for ch in text:
        if ch == " ":
            tap((letters if layer == "letters" else numbers)["space"])
        elif ch.isalpha():
            if layer != "letters":
                tap(numbers["letters"])
                layer = "letters"
            tap(letters[ch.upper()])
        else:
            if layer != "numbers":
                tap(letters["numbers"])
                layer = "numbers"
            tap(numbers[ch])
    return " ".join(taps)
