#!/usr/bin/python3
"""Capture the real lyrics reader with invented sample data.

Run through an exclusive GPU lock. Requires the installed Omarchy shell,
Quickshell, python-pillow and an OpenGL-capable GPU. Production BarWidget.qml,
LyricsView.qml, Service.qml and Model.js are copied into a temporary host; the
copied service never reads MPRIS and never starts the fetch helper, so no
player is touched and nothing goes to the network. Only window plumbing is
adapted for the offscreen platform.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(__file__).resolve().parent
# Rendered at five times the logical size, so the marketplace card can show
# the reader large without upscaling it.
SCALE = 5

# Invented artist, song and words, written for this capture.
LYRICS = """[00:08.00]Paper lanterns on the water
[00:12.40]drifting out past the harbour light
[00:16.80]every one a little promise
[00:21.10]that we wrote and set alight
[00:25.50]
[00:27.00]Hold the line, hold the line
[00:31.20]while the tide pulls the evening in
[00:35.60]count them out, one by one
[00:39.90]till the dark lets the glow begin
[00:44.30]
[00:46.00]Salt on the glass, chalk on the stair
[00:50.30]a radio humming a half-remembered air
[00:54.70]you said the river keeps it all
[00:59.00]so I let go slow
[01:03.40]
[01:05.00]Paper lanterns, paper lanterns
[01:09.30]carry what we could not say
[01:13.70]out beyond the breakwater
[01:18.00]where the morning finds its way
[01:22.40]
[01:24.00]Fold the paper, light the wick
[01:28.30]watch the little fires float
[01:32.70]every one a word we meant
[01:37.00]sailing in a paper boat"""

TRACK = {
    "artist": "Marisol Vey",
    "title": "Paper Lanterns",
    "album": "Low Tide Atlas",
    "length": 212,
    "position": 33.0,
}


def draw_cover(path):
    """An abstract cover: a warm gradient with a few soft rings."""
    from PIL import Image, ImageDraw, ImageFilter
    size = 256
    image = Image.new("RGB", (size, size))
    pixels = image.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * size)
            pixels[x, y] = (int(40 + 190 * t), int(28 + 90 * t * t), int(70 - 40 * t))
    rings = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(rings)
    for cx, cy, r, alpha in [(170, 90, 46, 150), (90, 170, 70, 90), (190, 200, 24, 200)]:
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 214, 160, alpha))
    rings = rings.filter(ImageFilter.GaussianBlur(3))
    image.paste(rings, (0, 0), rings)
    image.save(path)


def wait_for(predicate, description, timeout=20):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate(): return
        time.sleep(.1)
    raise RuntimeError("Timed out: " + description)


def complete_png(path):
    if not path.exists() or path.stat().st_size < 12: return False
    with path.open("rb") as image:
        image.seek(-12, 2)
        return image.read() == b'\x00\x00\x00\x00IEND\xaeB`\x82'


def drop_block(text, start_pattern):
    m = re.search(start_pattern, text, re.M)
    if not m: raise SystemExit(f"pattern not found: {start_pattern}")
    i = text.index("{", m.start())
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{": depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[:m.start()] + text[text.index("\n", j) + 1:]
    raise SystemExit("unbalanced block")


def replace_once(path, old, new):
    text = path.read_text()
    if text.count(old) != 1: raise SystemExit(f"{path.name}: expected one {old!r}")
    path.write_text(text.replace(old, new))


def offscreen_popup(path):
    """PopupCard is an xdg popup anchored to the bar, which the offscreen
    platform cannot place. Keep its card (BorderSurface, colours, border,
    padding, radius) and swap only the window and its Hyprland focus grab."""
    text = path.read_text()
    text = text.replace("import Quickshell.Hyprland\n", "")
    text = re.sub(r"^PopupWindow \{", "FloatingWindow {\n  property alias captureCard: card", text, count=1, flags=re.M)
    text = drop_block(text, r"^  HyprlandFocusGrab \{")
    text = drop_block(text, r"^  anchor \{")
    # A floating window keeps the size it was created with, so it covers the
    # screen and the card takes the size the popup asks for.
    for old, new in [("  implicitWidth: contentWidth\n", "  implicitWidth: 1400\n"),
                     ("  implicitHeight: contentHeight\n", "  implicitHeight: 900\n"),
                     ("    id: card\n    anchors.fill: parent\n",
                      "    id: card\n    width: root.contentWidth\n    height: root.contentHeight\n")]:
        if text.count(old) != 1: raise SystemExit(f"PopupCard.qml: expected one {old!r}")
        text = text.replace(old, new)
    path.write_text(text)


def main():
    output = ROOT / "screenshots"
    output.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="lyrics-capture-") as work_path:
        work = Path(work_path)
        home, shell, runtime = (work / name for name in ["home", "shell", "runtime"])
        runtime.mkdir(mode=0o700)
        shell.mkdir()
        theme = home / ".local/state/omarchy/current/next-theme"
        theme.mkdir(parents=True)
        shutil.copy("/usr/share/omarchy/themes/ristretto/colors.toml", theme / "colors.toml")
        env = dict(HOME=str(home), PATH="/usr/bin:/bin", LANG="C.UTF-8",
                   XDG_RUNTIME_DIR=str(runtime), OMARCHY_PATH="/usr/share/omarchy",
                   DISPLAY=os.environ.get("DISPLAY", ":0"))
        if "XAUTHORITY" in os.environ: env["XAUTHORITY"] = os.environ["XAUTHORITY"]
        subprocess.run(["omarchy-theme-set-templates"], env=env, check=True, stdout=subprocess.DEVNULL)
        shutil.copytree(theme, theme.with_name("theme"))
        fonts = home / ".config/fontconfig"
        fonts.mkdir(parents=True)
        (fonts / "fonts.conf").write_text('''<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd"><fontconfig>
<match target="pattern"><test name="family"><string>monospace</string></test>
<edit name="family" mode="assign" binding="strong"><string>JetBrainsMono Nerd Font</string></edit></match>
</fontconfig>''')
        for name in ["Commons", "Ui"]:
            shutil.copytree(Path("/usr/share/omarchy/shell") / name, shell / name)
        offscreen_popup(shell / "Ui/PopupCard.qml")

        plugin = work / "plugin"
        plugin.mkdir()
        for name in ["BarWidget.qml", "LyricsView.qml", "Service.qml", "Model.js",
                     "Artwork.qml", "Artwork.js", "bin/artwork"]:
            (plugin / name).parent.mkdir(exist_ok=True)
            shutil.copy(ROOT / name, plugin / name)
        service = plugin / "Service.qml"
        # No MPRIS: the host hands the service a sample player instead.
        replace_once(service, "readonly property var players: Mpris.players ? Mpris.players.values : []",
                     "readonly property var players: []")
        replace_once(service, "readonly property var activePlayer: chooseActivePlayer()",
                     "property var activePlayer: null")
        # No lookups: the host adopts a sample record instead.
        replace_once(service, "onTriggered: root.startLookup()", "onTriggered: {}")
        replace_once(service, "Qt.callLater(function () { getProc.running = true })", "")
        replace_once(service, "Qt.callLater(function () { searchProc.running = true })", "")
        replace_once(plugin / "BarWidget.qml", "  property bool popupOpen: false",
                     "  property bool popupOpen: false\n  property alias captureReader: reader\n  property alias capturePopup: popup")
        shutil.copy(TOOLS / "shell.qml", shell / "shell.qml")

        draw_cover(work / "cover.png")
        record = {"id": 1, "artist": TRACK["artist"], "track": TRACK["title"], "album": TRACK["album"],
                  "duration": TRACK["length"], "instrumental": False, "synced": LYRICS,
                  "plain": "\n".join(line[10:] for line in LYRICS.splitlines())}
        (work / "fixtures.json").write_text(json.dumps(dict(TRACK, record=record, cover="file://" + str(work / "cover.png"))))
        (work / "screen.json").write_text(json.dumps({"screens": [dict(name="CAPTURE", x=0, y=0, width=1400 * SCALE, height=900 * SCALE, logicalDpi=96, logicalBaseDpi=96, dpr=1)]}))
        env.update(QT_QPA_PLATFORM=f"offscreen:configfile={work / 'screen.json'}",
                   QT_QUICK_BACKEND="rhi", QSG_RHI_BACKEND="opengl", QSG_INFO="1", QT_SCALE_FACTOR=str(SCALE),
                   LYRICS_PLUGIN=str(plugin), LYRICS_FIXTURES=str(work / "fixtures.json"), LYRICS_OUTPUT=str(output))
        log = work / "qs.log"

        def call(method, *args):
            result = subprocess.run(["qs", "ipc", "-p", str(shell), "call", "--", "capture", method, *map(str, args)],
                                    env=env, capture_output=True, text=True, timeout=10)
            if result.returncode != 0:
                if method != "ready": print(result.stderr, file=sys.stderr, flush=True)
                return ""
            return result.stdout.strip()

        def grab(filename):
            path = output / filename
            path.unlink(missing_ok=True)
            result = call("grab", str(path))
            if result != "ok": raise RuntimeError(result)
            wait_for(lambda: complete_png(path), filename)
            print(path, file=sys.stderr, flush=True)

        with log.open("w") as stream:
            proc = subprocess.Popen(["qs", "-p", str(shell)], env=env, stdout=stream, stderr=subprocess.STDOUT)
            try:
                wait_for(lambda: call("ready") == "true", "capture host")
                state = json.loads(call("play"))
                assert state["state"] == "ready" and state["synced"] and state["activeIndex"] >= 0, state
                print(state, file=sys.stderr, flush=True)
                # The list is aligned to start on a whole line, and a text
                # size and height are chosen at which it also ends on one, so
                # neither panel shows a sliver of a line at its edges.
                for expanded, sizes, heights, filename in [("false", (17, 16, 15), (72,), "compact.png"),
                                                           ("true", (15, 16, 17), range(70, 81), "expanded.png")]:
                    call("reader", expanded)
                    found = None
                    for size in sizes:
                        call("fontSize", size)
                        for height in heights:
                            call("panelHeight", height)
                            for _ in range(2):
                                time.sleep(.4)
                                call("settle")
                            time.sleep(.4)
                            cuts = json.loads(call("align"))
                            if ((cuts["top"] <= 1 or not cuts["topText"])
                                    and (cuts["bottom"] <= 1 or not cuts["bottomText"])):
                                found = cuts
                                break
                        if found: break
                    if not found: raise RuntimeError(f"no clean layout for {filename}: {cuts}")
                    print(filename, found, file=sys.stderr, flush=True)
                    time.sleep(.5)
                    grab(filename)
            finally:
                proc.terminate()
                proc.wait(timeout=5)
                log_text = log.read_text()
                (output / "capture.log").write_text(log_text)
                for line in log_text.splitlines():
                    if "OpenGL VENDOR" in line or "OpenGL RENDERER" in line or "WARN" in line or "ERROR" in line:
                        print(line, file=sys.stderr)
        if "NVIDIA" not in log_text or "llvmpipe" in log_text or "Software" in log_text:
            raise RuntimeError("Capture must use GPU rendering; inspect screenshots/capture.log")
    subprocess.run([sys.executable, str(TOOLS / "preview.py")], check=True)


if __name__ == "__main__": main()
