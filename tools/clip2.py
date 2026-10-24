#!/usr/bin/env python3
"""Command-line tool for the Narrative Clip 2 (USB f0f0:cafe) -- no account, cloud or official app needed.

Part of Alternative Clip (unofficial; not affiliated with Narrative AB). See docs/PROTOCOL.md.
Requires: pip install pyusb, and libusb (brew install libusb).

Protocol (reconstructed by the community from the original Narrative Uploader,
see github.com/chrisv-uk/NarrativeClip): vendor control transfers on EP0,
replies on bulk EP 0x81.

  0xC0 req 4  GET_PARAMETER  wIndex=param         -> b'\\0' + value
  0x40 req 5  SET_PARAMETER  wIndex=param, 4B LE  -> "ACK" on bulk
  0x40 req 2  FILE_FROM_DEVICE payload=path       -> 132B header + data on bulk
  0x40 req 3  DEL_FILE        payload=path        -> "ACK"
  0x40 req 9  GET_DIRECTORY   payload=path        -> 132B records, sentinel-terminated
  0x40 req 18 RUN_COMMAND     payload=command, JSON on bulk OUT -> 264B status on bulk
  0x40 req 19 GET_PROPERTY_AS_JSON payload=name   -> 264B status + JSON on bulk
  (property / command names come from the firmware's D-Bus service com.narrative.Parhand)

Usage:
  clip2.py info
  clip2.py scan
  clip2.py pull [--dest DIR] [--no-snap]
  clip2.py verify [--dest DIR]                  re-read camera files, compare SHA-256 with Mac copies
  clip2.py clear  [--dest DIR] --yes-delete     delete camera photos ONLY if Mac copy matches byte-for-byte
  clip2.py set-interval SECONDS
  clip2.py sync-clock
  clip2.py set-sound on|off                     shooting beeps (one switch for timer and taps)
  clip2.py set-duration SECONDS [tap]           video length, 7-30 s (timer videos; "tap" for tap videos)
  clip2.py set-quality 1080p30                  video preset (1080p30 is the max; 1080p50/60 are rejected)
  clip2.py actions                              show what timer / taps do (TakePicture, RecordVideo, ...)
  clip2.py set-action timer|doubletap|tripletap None|TakePicture|RecordVideo|TakePictureBurst
"""
import argparse, datetime as dt, hashlib, json, os, re, struct, sys, time
import usb.core, usb.util, usb.backend.libusb1

VID, PID = 0xF0F0, 0xCAFE
EP_IN = 0x81
SENTINEL = bytes([0x00, 0xFF, 0xFF, 0x55, 0xAA, 0xFF, 0xFF, 0x00])
REC = 132
# Parameter 7 is the uploader's Enabled flag (not double tap); double tap is set via set-action.
P_SERIAL, P_HWREV, P_FW, P_BATTERY, P_INTERVAL, P_RTC, P_NAME, P_AUDIO = 2, 3, 4, 5, 6, 10, 19, 27
# Clip 2 parameter ids follow the firmware's property table: 20 VideoDuration, 21 CameraActionVideoDuration,
# 22 ConfiguredActions, 26 VideoQuality. Do NOT read 18 / 23 (replies > 1056 bytes jam the pipe).
P_VIDEO_QUALITY = 26
DEFAULT_DEST = os.path.expanduser("~/Pictures/Alternative Clip")  # same default as the app
EVENT_RE = re.compile(r"^event_([0-9a-f]{12})_(\d{10})_(\d{8})T(\d{6})Z\.(.+)$")
LIBUSB_PATHS = ["/opt/homebrew/lib/libusb-1.0.dylib", "/usr/local/lib/libusb-1.0.dylib"]


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


class Clip:
    def __init__(self):
        lib = next((p for p in LIBUSB_PATHS if os.path.exists(p)), None)
        be = usb.backend.libusb1.get_backend(find_library=lambda _: lib) if lib else None
        self.d = usb.core.find(idVendor=VID, idProduct=PID, backend=be)
        if self.d is None:
            raise SystemExit("Narrative Clip 2 not found. Is it connected over USB?")
        try:
            self.d.get_active_configuration()
        except usb.core.USBError:
            self.d.set_configuration()
        usb.util.claim_interface(self.d, 0)
        self.drain()

    def close(self):
        try:
            usb.util.release_interface(self.d, 0)
            usb.util.dispose_resources(self.d)
        except Exception:
            pass

    def read(self, timeout=15000):
        try:
            return bytes(self.d.read(EP_IN, 65536, timeout))
        except usb.core.USBTimeoutError:
            return None

    def drain(self):
        while self.read(300):
            pass

    # --- parameters
    def param(self, p):
        return bytes(self.d.ctrl_transfer(0xC0, 4, 0, p, 1056, 5000))

    def param_str(self, p):
        return self.param(p).strip(b"\0").decode(errors="replace")

    def param_u32(self, p):
        r = self.param(p)
        return struct.unpack("<I", r[1:5].ljust(4, b"\0"))[0]

    def set_param(self, p, value):
        self.drain()
        self.d.ctrl_transfer(0x40, 5, 0, p, struct.pack("<I", value), 5000)
        time.sleep(0.2)
        r = self.read(5000) or b""
        return r[:3] == b"ACK"

    def _status(self):
        buf = b""
        while len(buf) < 264:
            r = self.read(5000)
            if not r:
                raise IOError("short command status")
            buf += r
        code, size = struct.unpack("<iI", buf[:8])
        msg = buf[8:264].split(b"\0")[0].decode(errors="replace")
        return code, size, msg, buf[264:]

    def prop(self, name):
        """Read a firmware D-Bus property as JSON (e.g. ConfiguredActions, VideoQuality)."""
        self.drain()
        self.d.ctrl_transfer(0x40, 19, 0, 0, name.encode(), 5000)
        code, size, msg, data = self._status()
        while len(data) < size:
            r = self.read(5000)
            if not r:
                break
            data += r
        if code != 0:
            raise IOError(f"{name}: {msg} ({code})")
        return json.loads(data[:size].rstrip(b"\0").decode())[name]

    def run(self, command, payload):
        """Run a firmware D-Bus method (e.g. ConfigureActions) with a JSON string argument."""
        self.drain()
        self.d.clear_halt(0x02)  # OUT endpoint can be left halted; writes fail with EIO otherwise
        self.d.ctrl_transfer(0x40, 18, 0, 0, command.encode(), 5000)
        time.sleep(0.1)
        self.d.write(0x02, payload.encode(), 60000)
        code, _, msg, _ = self._status()
        if code != 0:
            raise IOError(f"{command}: {msg} ({code})")

    def set_param_str(self, p, value):
        self.drain()
        self.d.ctrl_transfer(0x40, 5, 0, p, value.encode(), 5000)
        time.sleep(0.3)
        r = self.read(5000) or b""
        return r[:3] == b"ACK"

    def info(self):
        bat = self.param(P_BATTERY)
        return {
            "serial": self.param_str(P_SERIAL),
            "hardware": self.param_str(P_HWREV),
            "firmware": self.param_str(P_FW),
            "name": self.param_str(P_NAME),
            "battery_raw": bat.hex(),
            "battery_percent?": bat[1] if len(bat) > 1 else None,
            "interval_s": self.param_u32(P_INTERVAL),
            "audio_feedback": self.param_u32(P_AUDIO),
            "clock_utc": dt.datetime.fromtimestamp(self.param_u32(P_RTC), dt.timezone.utc).isoformat(),
        }

    # --- filesystem
    def listdir(self, path):
        self.d.ctrl_transfer(0x40, 9, 0, 0, path.encode(), 5000)
        buf = b""
        while True:
            chunk = self.read(15000)
            if not chunk:
                break
            buf += chunk
            n = len(buf) // REC
            if n and buf[(n - 1) * REC + 8:(n - 1) * REC + 16] == SENTINEL:
                break
        out = []
        for i in range(len(buf) // REC):
            rec = buf[i * REC:(i + 1) * REC]
            if rec[8:16] == SENTINEL:
                continue
            size, typ = struct.unpack("<IB", rec[:5])
            name = rec[8:].split(b"\0")[0].decode(errors="replace")
            if name in (".", ".."):
                continue
            out.append((name, typ == 4, size))
        return out

    def get(self, path):
        self.d.ctrl_transfer(0x40, 2, 0, 0, path.encode(), 5000)
        buf = b""
        while len(buf) < REC:
            c = self.read(15000)
            if c is None:
                raise IOError(f"no header for {path}")
            buf += c
        size = struct.unpack("<I", buf[:4])[0]
        name = buf[8:REC].split(b"\0")[0].decode(errors="replace")
        data = bytearray(buf[REC:])
        empties = 0
        while len(data) < size:
            c = self.read(15000)
            if c is None:
                raise IOError(f"stalled on {path} ({len(data)}/{size})")
            if not c:
                empties += 1
                if empties > 8:
                    raise IOError(f"empty packets on {path}")
                continue
            data += c
        if size and size % 512 == 0:
            self.read(300)
        if len(data) != size:
            raise IOError(f"size mismatch {path}: {len(data)} != {size}")
        return bytes(data), size, name

    def delete(self, path):
        self.drain()
        self.d.ctrl_transfer(0x40, 3, 0, 0, path.encode(), 5000)
        time.sleep(0.2)
        r = self.read(5000) or b""
        return r[:3] == b"ACK"

    def events(self):
        """Yield (device_path, name, size) for every file under /events, chronological."""
        files = []
        for dname, isdir, _ in self.listdir("/events"):
            if isdir and re.fullmatch(r"\d{10}", dname):
                for fname, fisdir, size in self.listdir(f"/events/{dname}"):
                    if not fisdir:
                        files.append((f"/events/{dname}/{fname}", fname, size))
        files.sort(key=lambda f: f[1])
        return files


def local_path(dest, name):
    m = EVENT_RE.match(name)
    if not m:
        return None
    ymd = m.group(3)
    # Filenames carry UTC; folder by local (JST etc.) date of capture
    t = capture_time(name)
    day = t.astimezone().strftime("%Y-%m-%d") if t else f"{ymd[:4]}-{ymd[4:6]}-{ymd[6:]}"
    return os.path.join(dest, day, name)


def capture_time(name):
    m = EVENT_RE.match(name)
    if not m:
        return None
    t = dt.datetime.strptime(m.group(3) + m.group(4), "%Y%m%d%H%M%S").replace(tzinfo=dt.timezone.utc)
    return None if t.year < 2014 else t  # clock reset -> year 2000; don't trust


def is_media(name, with_snap):
    return with_snap or not name.endswith(".snap.bin")  # everything under /events


def sha(b):
    return hashlib.sha256(b).hexdigest()


def cmd_pull(clip, args):
    files = [f for f in clip.events() if is_media(f[1], not args.no_snap)]
    todo = []
    for path, name, size in files:
        lp = local_path(args.dest, name)
        if lp and not (os.path.exists(lp) and os.path.getsize(lp) == size):
            todo.append((path, name, size, lp))
    need = sum(f[2] for f in todo)
    st = os.statvfs(args.dest if os.path.exists(args.dest) else os.path.expanduser("~"))
    free = st.f_bavail * st.f_frsize
    log(f"camera files: {len(files)}, new: {len(todo)} ({need/1e9:.2f} GB), Mac free: {free/1e9:.1f} GB")
    if need > free - 5e9:
        raise SystemExit("Not enough free space (5 GB is kept free). Use --dest to pick another disk.")
    hashes = {}
    t0 = time.time(); done_bytes = 0
    for i, (path, name, size, lp) in enumerate(todo, 1):
        for attempt in range(3):
            try:
                data, hsize, hname = clip.get(path)
                if hsize != size or (hname and not hname.endswith("/" + name)):
                    raise IOError(f"header mismatch {hname} {hsize}")
                break
            except (IOError, usb.core.USBError) as e:
                log("retry", name, e); clip.drain(); time.sleep(1)
        else:
            raise SystemExit(f"failed: {path}")
        os.makedirs(os.path.dirname(lp), exist_ok=True)
        tmp = lp + ".part"
        with open(tmp, "wb") as fh:
            fh.write(data); fh.flush(); os.fsync(fh.fileno())
        os.replace(tmp, lp)
        t = capture_time(name)
        if t:
            os.utime(lp, (t.timestamp(), t.timestamp()))
        hashes[lp] = sha(data)
        done_bytes += size
        if i % 50 == 0 or i == len(todo):
            rate = done_bytes / max(time.time() - t0, 0.001) / 1e6
            log(f"{i}/{len(todo)}  {done_bytes/1e9:.2f} GB  {rate:.1f} MB/s")
    # append to hash ledger
    ledger = os.path.join(args.dest, "sha256.txt")
    with open(ledger, "a") as fh:
        for lp, h in hashes.items():
            fh.write(f"{h}  {os.path.relpath(lp, args.dest)}\n")
    log("pull done")


def cmd_verify(clip, args, delete=False):
    files = [f for f in clip.events() if is_media(f[1], True) or delete]
    ok = bad = missing = deleted = 0
    for path, name, size in files:
        lp = local_path(args.dest, name)
        if not lp or not os.path.exists(lp):
            missing += 1
            continue
        data, _, _ = clip.get(path)
        with open(lp, "rb") as fh:
            local = fh.read()
        if sha(data) == sha(local):
            ok += 1
            if delete:
                if clip.delete(path):
                    deleted += 1
                else:
                    log("delete failed", path)
        else:
            bad += 1
            log("MISMATCH", name)
    log(f"verified ok={ok} mismatch={bad} not-on-mac={missing}" + (f" deleted={deleted}" if delete else ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd")
    ap.add_argument("value", nargs="?")
    ap.add_argument("extra", nargs="?")
    ap.add_argument("--dest", default=DEFAULT_DEST)
    ap.add_argument("--no-snap", action="store_true", help="skip .snap.bin (raw GPS snapshots)")
    ap.add_argument("--yes-delete", action="store_true")
    args = ap.parse_args()
    clip = Clip()
    try:
        if args.cmd == "info":
            print(json.dumps(clip.info(), indent=2, ensure_ascii=False))
        elif args.cmd == "scan":
            files = clip.events()
            kinds = {}
            for _, n, s in files:
                k = n.rsplit("_", 1)[-1].split(".", 1)[-1]
                c, b = kinds.get(k, (0, 0)); kinds[k] = (c + 1, b + s)
            for k, (c, b) in sorted(kinds.items()):
                print(f"{k:12} {c:7} files {b/1e9:7.2f} GB")
            days = sorted({local_path("", n).split("/")[0] for _, n, _ in files if local_path("", n) and n.endswith(".jpg")})
            print("days:", ", ".join(days))
        elif args.cmd == "pull":
            os.makedirs(args.dest, exist_ok=True)
            cmd_pull(clip, args)
        elif args.cmd == "verify":
            cmd_verify(clip, args)
        elif args.cmd == "clear":
            if not args.yes_delete:
                raise SystemExit("clear needs --yes-delete (only files whose Mac copy matches byte for byte are deleted)")
            cmd_verify(clip, args, delete=True)
        elif args.cmd == "set-interval":
            print("ACK" if clip.set_param(P_INTERVAL, int(args.value)) else "NO ACK", clip.param_u32(P_INTERVAL))
        elif args.cmd == "sync-clock":
            print("ACK" if clip.set_param(P_RTC, int(time.time())) else "NO ACK", clip.info()["clock_utc"])
        elif args.cmd == "actions":
            for n in ["ConfiguredActions", "TimerActionInterval", "CameraActionVideoDuration", "VideoDuration", "VideoQuality"]:
                print(n, "=", json.dumps(clip.prop(n), ensure_ascii=False))
        elif args.cmd == "set-sound":
            # AudioFeedbackEnabled: one switch for every beep (timer and taps alike)
            ok = clip.set_param(P_AUDIO, 1 if args.value == "on" else 0)
            print("ACK" if ok else "rejected", "AudioFeedbackEnabled =", clip.prop("AudioFeedbackEnabled"))
        elif args.cmd == "set-duration":
            # 20 = timer videos (VideoDuration), 21 = tap videos (CameraActionVideoDuration); camera allows 7-30 s
            pid = 21 if args.extra == "tap" else 20
            print("ACK" if clip.set_param(pid, int(args.value)) else "rejected", clip.param_u32(pid))
        elif args.cmd == "set-quality":
            ok = clip.set_param_str(P_VIDEO_QUALITY, args.value)
            print("ACK" if ok else "rejected", clip.param_str(P_VIDEO_QUALITY))
        elif args.cmd == "set-action":
            key = {"timer": "onTimer", "doubletap": "onDoubleTap", "tripletap": "onTripleTap"}[args.value]
            new = args.extra
            if new not in ("None", "TakePicture", "RecordVideo", "TakePictureBurst"):
                ap.error("action must be None, TakePicture, RecordVideo or TakePictureBurst")
            cur = clip.prop("ConfiguredActions")
            print("before:", json.dumps(cur))
            cur[key] = new
            clip.run("ConfigureActions", json.dumps(cur))
            print("after: ", json.dumps(clip.prop("ConfiguredActions")))
        else:
            ap.error("unknown command")
    finally:
        clip.close()


if __name__ == "__main__":
    main()
