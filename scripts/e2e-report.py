#!/usr/bin/env python3
"""Timings for scripts/e2e-sync.sh from the Mac's and the iPhone's self-test logs.

Both apps run on one Mac, so they share a clock. The Mac log stamps wall time; the iPhone log stamps seconds since
it started, so its offset comes from `ping` commands whose write time the script recorded (marks.txt): the offset
is the largest (write time - logged offset), which is low by at most the app's 250 ms command-file poll.
Usage: e2e-report.py <out dir>
"""
import re
import sys
import time
from pathlib import Path

out = Path(sys.argv[1])
mac = (out / "mac.log").read_text().splitlines()
ios = (out / "iphone.log").read_text().splitlines()
marks = [l.split(" ", 1) for l in (out / "marks.txt").read_text().splitlines()]


def sod(epoch):
    t = time.localtime(epoch)
    return t.tm_hour * 3600 + t.tm_min * 60 + t.tm_sec + (epoch % 1)


MAC_RE = re.compile(r"^\[\+\s*([\d.]+)s\] (\d\d):(\d\d):(\d\d)\.(\d\d\d) (.*)$")
IOS_RE = re.compile(r"^\[\+\s*([\d.]+)s\] (.*)$")
mac_ev = []
for l in mac:
    m = MAC_RE.match(l)
    if m:
        h, mi, s, ms = (int(x) for x in m.group(2, 3, 4, 5))
        mac_ev.append((h * 3600 + mi * 60 + s + ms / 1000, m.group(6)))
ios_rel = []
for l in ios:
    m = IOS_RE.match(l)
    if m:
        ios_rel.append((float(m.group(1)), m.group(2)))

offsets = []
for t, what in marks:
    if what.startswith("ping "):
        i = what.split()[1]
        for r, text in ios_rel:
            if text.startswith("TEST ping") and f"i={i}" in text:
                offsets.append(sod(float(t)) - r)
                break
if not offsets:
    sys.exit("no ping lines in the iPhone log")
offset = max(offsets)
ios_ev = [(r + offset, text) for r, text in ios_rel]
# The offset is a lower bound (a ping is handled up to one 250 ms poll after it is written), so an iPhone event can
# land up to that much before the script's mark for it: marks used to find iPhone events allow for that.
POLL = 0.3
mark_at = {what: sod(float(t)) for t, what in marks}


def first(events, pattern, after=0.0):
    rx = re.compile(pattern)
    for t, text in events:
        if t >= after and rx.search(text):
            return t, text
    return None, None


def num(pattern, text, default=None):
    m = re.search(pattern, text or "")
    return float(m.group(1)) if m else default


P0 = r'delta (-?\d+) ms'
P1 = r'delivered in (\d+) ms'
P2 = r'acked playing (\d+) ms'
P3 = r'paused here (\d+) ms'
P4 = r'at ([\d.]+)s'
P5 = r'(\d+) ms after the tap'
P6 = r'(\d+) ms after it was written'

rows = []
print(f"iPhone log clock offset from {len(offsets)} pings (spread {1000 * (max(offsets) - min(offsets)):.0f} ms)\n")

# a. pull: Mac -> iPhone
tap_a, tap_text = first(ios_ev, r"^TAP play here from Mac", mark_at.get("tap a playhere", 0) - POLL)
pull_t, pull = first(ios_ev, r"^PULL (done|failed)", tap_a or 0)
print("a. Mac plays Discovery 1 at ~1:00; the iPhone continues it")
print("   iPhone banner:", (first(ios_ev, r"^BANNER Continue from Mac")[1] or "-"))
print("   iPhone:", tap_text)
print("   iPhone:", pull)
if tap_a and pull and pull.startswith("PULL done"):
    playing_ms = num(r"playing (\d+) ms", pull)
    delta = num(r"delta (-?\d+) ms", pull)
    paused_t, paused = first(mac_ev, r"^PLAYER paused", tap_a)
    cmd_t, cmd = first(mac_ev, r"^COMMAND pause from iPhone", tap_a)
    src_t, src = first(ios_ev, r"^REMOTE-STATE Mac: paused.*delta", tap_a)
    print("   Mac:", cmd)
    print("   Mac:", paused, f"(at {paused_t:.3f})" if paused_t else "")
    print("   iPhone:", src)
    rows.append(("a", "iPhone Play Here: tap to playing", f"{playing_ms:.0f} ms"))
    rows.append(("a", "position delta at start (iPhone minus Mac's live position)", f"{delta:+.0f} ms"))
    if src:
        rows.append(("a", "position delta when the Mac paused (iPhone minus Mac)", f"{num(P0, src):+.0f} ms"))
    if paused_t:
        rows.append(("a", "tap on the iPhone to the Mac paused", f"{1000 * (paused_t - tap_a):.0f} ms"))
        rows.append(("a", "iPhone playing to the Mac paused", f"{1000 * (paused_t - tap_a) - playing_ms:.0f} ms"))
    if cmd:
        rows.append(("a", "pause command delivery to the Mac (server clock)", f"{num(P1, cmd):.0f} ms"))

# b. push: iPhone -> Mac
tap_b, tap_text = first(ios_ev, r"^TAP send to Mac", mark_at.get("tap b send", 0) - POLL)
push_t, push = first(ios_ev, r"^PUSH (done|failed)", tap_b or 0)
print("\nb. The iPhone sends playback to the Mac")
print("   iPhone:", push)
if tap_b and push and push.startswith("PUSH done"):
    play_t, play = first(mac_ev, r"^PLAYER playing", tap_b)
    cmd_t, cmd = first(mac_ev, r"^COMMAND takeOver from iPhone", tap_b)
    st_t, st = first(mac_ev, r"^REMOTE-STATE iPhone: paused", tap_b)
    print("   Mac:", cmd)
    print("   Mac:", play)
    print("   Mac:", st)
    rows.append(("b", "tap Send on the iPhone to the Mac's ack (Mac playing)", f"{num(P2, push):.0f} ms"))
    rows.append(("b", "tap to the iPhone paused", f"{num(P3, push):.0f} ms"))
    if play_t:
        rows.append(("b", "tap to the Mac's player reporting playing", f"{1000 * (play_t - tap_b):.0f} ms"))
    if cmd:
        rows.append(("b", "takeOver delivery to the Mac (server clock)", f"{num(P1, cmd):.0f} ms"))
    if st:
        # Where the iPhone paused vs where the Mac started.
        pos_ios = num(r"at ([\d.]+)s", st)
        mac_pos_t, mac_pos = first(mac_ev, r"^PLAYER playing", tap_b)
        print(f"   iPhone paused at {pos_ios}s; Mac started at {num(P4, mac_pos)}s")
        if pos_ios is not None and mac_pos:
            rows.append(("b", "Mac start position minus where the iPhone paused", f"{1000 * (num(P4, mac_pos) - pos_ios):+.0f} ms"))

# c. remote control
print("\nc. Remote control")
for who, events in (("Mac -> iPhone", mac_ev), ("iPhone -> Mac", ios_ev)):
    for t, text in events:
        if text.startswith("REMOTE ") and "acked" in text:
            label = text.split()[1]
            print(f"   {who}: {text}")
            rows.append(("c", f"{who} {label}: tap to ack", f"{num(P5, text):.0f} ms" + ("" if "ok=true" in text else " (FAILED)")))
for t, text in ios_ev:
    if text.startswith("COMMAND ") and "from Mac" in text:
        print("   iPhone:", text)
for t, text in mac_ev:
    if text.startswith("COMMAND ") and "from iPhone" in text and t > (mark_at.get("remote mac->iphone pause", 0) + 1):
        print("   Mac:", text)

# d. settings and sign-ins
print("\nd. Settings and sign-ins")
_, s = first(ios_ev, r"^SETTING playback.crossfadeSeconds → 6")
print("   iPhone:", s)
if s:
    rows.append(("d", "crossfade set on the Mac, applied on the iPhone (after the 400 ms debounce)", f"{num(P6, s):.0f} ms"))
_, s = first(mac_ev, r"^SIGNIN-TEST")
print("   Mac:", s)
_, s = first(ios_ev, r"^SIGN-IN youtubeMusic")
print("   iPhone:", s)
if s:
    rows.append(("d", "test sign-in made on the Mac, imported on the iPhone", f"{num(P6, s):.0f} ms"))
_, s = first(mac_ev, r"^SIGN-IN youtubeMusic signed out everywhere")
print("   Mac:", s)
if s:
    rows.append(("d", "sign out on all devices (iPhone) to the Mac signed out", f"{num(P6, s):.0f} ms"))
left_t = first(mac_ev, r"^LEFT sync")[0] or float("inf")
statuses = [text for t, text in mac_ev if t < left_t and text.strip().startswith("sign-in youtubeMusic")]
if statuses:
    print("   Mac before leaving:", statuses[-1].strip())

wake_t = mark_at.get("wake posted")
if wake_t:
    w_t, w = first(mac_ev, r"^FOREGROUND true \(wake\)", wake_t - 1)
    c_t, c = first(mac_ev, r"^CONNECTION connected", (w_t or wake_t))
    print("\nwake:", w, "->", c)
    if w_t and c_t:
        rows.append(("wake", "wake from sleep to reconnected (backoff was mid-wait)", f"{1000 * (c_t - w_t):.0f} ms"))
print("\n| Step | What | Measured |\n| --- | --- | --- |")
for step, what, value in rows:
    print(f"| {step} | {what} | {value} |")
