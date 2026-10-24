#!/usr/bin/env python3
"""Creates a fake library (generated images, test videos, meta.json) for screenshots.

    scripts/make_demo_library.py /tmp/demo-library
    "build/Alternative Clip.app/Contents/MacOS/AlternativeClip" --library /tmp/demo-library --snapshot docs/screenshots

Needs ffmpeg. No real photos are involved.
"""
import datetime as dt
import json
import os
import random
import subprocess
import sys

SERIAL = "0123456789ab"
out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/demo-library"
random.seed(7)


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *args], check=True)


def meta(kind, trigger, soc, mv, seq):
    return {
        "type": kind, "trigger": trigger, "fw_version": "v1.5.6-0-gdemo", "hw_rev": "Clip2 Rev1D",
        "state_of_charge": soc, "voltage": mv, "too_dark": 0, "light_meter": random.randint(300, 900),
        "aec_gain": 256, "aec_exp": 16, "image_seq": seq,
        "acc_data": {"now": [random.randint(-2000, 2000), -16000, random.randint(-2000, 2000)]},
    }


seq = 10000
start = dt.datetime(2026, 10, 18, 0, 30, tzinfo=dt.timezone.utc)  # 9:30 JST
for day in range(2):
    t = start + dt.timedelta(days=day)
    n = 30
    for i in range(n):
        seq += 1
        when = t + dt.timedelta(minutes=10 * i)
        local = when.astimezone()
        folder = os.path.join(out, local.strftime("%Y-%m-%d"))
        os.makedirs(folder, exist_ok=True)
        base = f"event_{SERIAL}_{seq:010d}_{when.strftime('%Y%m%dT%H%M%S')}Z"
        is_video = i % 6 == 5
        soc = max(2, 100 - int(i * 98 / (n - 1)))
        mv = int(4150 - (100 - soc) * 8.5)
        c0 = "#%06x" % random.randint(0, 0xFFFFFF)
        c1 = "#%06x" % random.randint(0, 0xFFFFFF)
        if is_video:
            ffmpeg("-f", "lavfi", "-i", f"gradients=s=540x960:c0={c0}:c1={c1}:speed=0.05:d=3",
                   "-c:v", "h264_videotoolbox" if sys.platform == "darwin" else "libx264", "-b:v", "2M",
                   os.path.join(folder, base + ".mp4"))
        else:
            ffmpeg("-f", "lavfi", "-i", f"gradients=s=1224x1632:c0={c0}:c1={c1}:x0=0:y0=0:x1=1224:y1=1632",
                   "-frames:v", "1", "-q:v", "4", os.path.join(folder, base + ".jpg"))
        with open(os.path.join(folder, base + ".meta.json"), "w") as f:
            json.dump(meta("Video" if is_video else "Photo", "RTC", soc, mv, seq), f)
print("demo library:", out)
