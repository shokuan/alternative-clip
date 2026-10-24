# Narrative Clip 2 USB protocol

What Alternative Clip knows about talking to a **Narrative Clip 2** over USB. It was put together from:

- the community reconstruction of the original *Narrative Uploader* protocol in
  [chrisv-uk/NarrativeClip](https://github.com/chrisv-uk/NarrativeClip) (`unarrativecamera.pas`),
- strings in the camera's own firmware image (read from the camera, never modified), and
- testing against one camera running firmware **v1.5.6** (hardware "Clip2 Rev1D").

Anything marked *unverified* has not been exercised on real hardware. Other firmware versions may differ.

> Nothing here writes firmware. Firmware upgrade (request 17) and the `FactoryReset` command exist,
> but Alternative Clip deliberately never sends them.

## USB device

| | |
|---|---|
| Vendor / product | `0xF0F0` / `0xCAFE` (Clip 1 is `0xF0F0` / `0x1337`) |
| bcdDevice | `0x0108` |
| Strings | manufacturer `Narrative`, product `Narrative Clip 2`, serial number = the camera's Wi-Fi MAC address (`xx:xx:xx:xx:xx:xx`) |
| Class | `0xFF` (vendor specific). macOS attaches no driver, so the device is **unconfigured** when it appears. |
| Configuration | `1`, interface `0` |
| Endpoints | `0x81` bulk IN (512 bytes), `0x02` bulk OUT (512 bytes) |
| Speed | USB 2.0 high speed. File transfer in practice: 1.4–4.7 MB/s |
| Recovery mode | `0x4255` / `0x0008` according to chrisv-uk (*unverified*) |

After plugging in, the camera can take up to ~30 s before it enumerates with valid descriptors (its Linux side is booting).

Select configuration 1 and claim interface 0. No kernel driver needs to be detached on macOS; user-space access
with IOUSBHost or libusb works without root.

## Requests

All commands are vendor control transfers to the device (`wValue = 0`). Replies, when there are any, arrive on bulk IN `0x81`.

| bRequest | Name | Direction | wIndex | Data stage | Reply on bulk IN |
|---|---|---|---|---|---|
| 2 | FILE_FROM_DEVICE | OUT `0x40` | 0 | path | 132-byte header, then the file |
| 3 | DEL_FILE | OUT `0x40` | 0 | path | `ACK\0` |
| 4 | GET_PARAMETER | IN `0xC0` | parameter id | (reply in the control data stage, up to 1056 bytes) | — |
| 5 | SET_PARAMETER | OUT `0x40` | parameter id | value (u32 LE or string) | `ACK\0` or `ERR\0` |
| 9 | GET_DIRECTORY | OUT `0x40` | 0 | path | 132-byte records, sentinel terminated |
| 11 | STORAGE_MODE | | | | *unused* |
| 14 | DEL_DIRECTORY | OUT `0x40` | 0 | path | `ACK\0` (*unverified*) |
| 16 | FILE_TO_DEVICE | OUT `0x40` | 0 | path, then u32 LE length + data on bulk OUT | `ACK\0` (*unverified*) |
| 17 | UPGRADE_FIRMWARE | | | | **never used** |
| 18 | RUN_COMMAND | OUT `0x40` | 0 | D-Bus method name; then a JSON argument on bulk OUT | 264-byte status |
| 19 | GET_PROPERTY_AS_JSON | OUT `0x40` | 0 | property name | 264-byte status + JSON |

Paths are plain UTF-8; a trailing NUL is accepted but not required. Paths are relative to the camera's storage
root (`/events`, `/fw`, ...). The firmware rejects paths outside its sandbox.

### 132-byte record

Used for directory entries and as the header in front of a file.

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | size, u32 LE |
| 4 | 1 | type: `4` = directory, `8` = file |
| 5 | 3 | reserved |
| 8 | 124 | name, NUL terminated |

A directory listing ends with a record whose name field starts with the sentinel
`00 FF FF 55 AA FF FF 00`. Listings include `.` and `..`.

In a file header the name is the camera's full internal path, e.g.
`/mnt/storage/nrtv//events/0000056900/event_…jpg`; compare only the last path component.
The file data follows directly. If the size is a multiple of 512, a zero-length packet follows the data.

### 264-byte status (requests 18 and 19)

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | code, i32 LE (`0` = success) |
| 4 | 4 | size of the JSON that follows, u32 LE |
| 8 | 256 | message, NUL terminated (e.g. `No such property: 'FreeSpace'`) |

## Parameters (requests 4 and 5)

GET_PARAMETER replies start with one status byte (`0x00`), followed by the value: a u32 LE number or a
NUL-terminated string. The ids follow the property table of the firmware's D-Bus service
(`com.narrative.Parhand`); names in the table are those properties.

| Id | Property | Type | Notes |
|---|---|---|---|
| 0 | Manufacturer | string | `Narrative AB` |
| 1 | ModelNumber | string | `Narrative Clip 2` |
| 2 | SerialNumber | string | 12 hex digits |
| 3 | HardwareRevision | string | |
| 4 | FirmwareRevision | string | e.g. `v1.5.6` |
| 5 | StateOfCharge | u8 | battery percent (the first byte after the status byte) |
| 6 | TimerActionInterval | u32 | **writable**, seconds, 10–300 (other values answer `ERR`) |
| 7 | UploaderService.Enabled | u32 | *older notes call this "disable double tap"; it isn't. Don't write it.* |
| 8 | AccessToken | | write only |
| 9 | UploaderStatus | JSON | e.g. `{"state":"IdleNoWifi",...}` |
| 10 | TimeOfDay | u32 | **writable**, camera clock, Unix time UTC |
| 11 | TotalBoots | u32 | |
| 12 | EventSequenceNumber | u32 | next capture sequence number |
| 13 | Wi-Fi CurrentNetwork | string | |
| 14 | Wi-Fi State | string | e.g. `scanning` |
| 15 | Wi-Fi IpAddresses | string | |
| 16 | Wi-Fi MacAddress | string | |
| 17 | Wi-Fi Networks | JSON | saved networks; SSIDs are base64 |
| 18 | Wi-Fi BSS | | **don't read**: reply is larger than 1056 bytes and jams the pipe |
| 19 | DeviceName | string | |
| 20 | VideoDuration | u32 | **writable**, timer-triggered video length, seconds (7–30) |
| 21 | CameraActionVideoDuration | u32 | writable (*unverified*), tap-triggered video length, seconds (7–30) |
| 22 | ConfiguredActions | JSON | see below |
| 23 | Status | | **don't read** (same problem as 18) |
| 24 | AutomaticFirmwareUpgrade | u32 | |
| 25 | BackendServer | string | the defunct cloud URL |
| 26 | VideoQuality | string | **writable**, see below |
| 27 | AudioFeedbackEnabled | u32 | **writable**, `0`/`1`: one switch for every capture beep (timer and taps) |

SET_PARAMETER takes a 4-byte little-endian value for numbers and the raw string for strings, and answers
`ACK\0` or `ERR\0` on bulk IN (give it ~200 ms).

## Properties as JSON (request 19)

Send the property name; the reply is the 264-byte status followed by `{"<Name>": value}`. Names that work:

`ConfiguredActions`, `TimerActionInterval`, `VideoDuration`, `CameraActionVideoDuration`, `VideoQuality`,
`AudioFeedbackEnabled`, `StateOfCharge`, `IsCharging`, `TotalBoots`, `ImageSettingsInformation`.

`ImageSettingsInformation` describes the valid settings. On firmware v1.5.6:

```json
{
  "timerActionInterval": {"type": "uint32", "minValue": 10, "maxValue": 300},
  "videoDuration": {"type": "uint32", "minValue": 7, "maxValue": 30},
  "cameraActionVideoDuration": {"type": "uint32", "minValue": 7, "maxValue": 30},
  "cameraAction": {"type": "enum", "values": ["", "None", "TakePicture", "RecordVideo", "ShowBatteryStatus"]},
  "videoQuality": {"type": "enum", "values": ["1080p30", "720p50", "480p30", "480p25", "240p25", "352p30",
    "VGAp30", "VGAp25", "720p60", "720p30", "480p60", "480p50", "240p30", "400p30", "1080p25", "720p25",
    "400p25", "352p25"]},
  "feedbackType": {"type": "enum", "values": ["FlashAllLEDs", "Beep"]},
  "audioFeedbackEnabled": {"type": "bool"}, "isCharging": {"type": "bool"},
  "currentTime": {"type": "uint32"}, "freeSpace": {"type": "uint64"}, "totalSpace": {"type": "uint64"}
}
```

`1080p30` is the highest quality; `1080p50`, `1080p60`, `1440p30` and `2160p30` are rejected.
Battery health (state of health, full-charge capacity) exists inside the firmware (a TI bq27421 fuel gauge)
but is not exposed over USB.

## Commands (request 18)

Send the method name in the control transfer, then the JSON argument as one bulk OUT transfer, then read the
264-byte status. Methods the USB daemon accepts: `ConfigureActions`, `TakePicture`, `Feedback`, `AddNetwork`,
`RemoveNetwork`, `SelectNetwork`, `BluetoothPairing`, `GenerateManifest`, `Reboot`, `PowerDown`, `FactoryReset`.
Alternative Clip only uses `ConfigureActions`.

### ConfigureActions: what each trigger does

```json
{"onTimer": "RecordVideo", "onDoubleTap": "None", "onTripleTap": "RecordVideo"}
```

Actions: `None`, `TakePicture`, `RecordVideo`, `TakePictureBurst`, `ShowBatteryStatus`.
Read the current value with property `ConfiguredActions` (or parameter 22). Factory default was
`onTimer: TakePicture`, `onTripleTap: RecordVideo`, `onDoubleTap: None`.
Setting `onTimer` to `RecordVideo` turns periodic capture into periodic video clips (tested). The camera may restart
and re-enumerate after this command.

## Pitfalls

- **Stale data.** Drain bulk IN (short timeouts until nothing arrives) before a command if the previous one failed or
  ended on a 512-byte boundary.
- **Halted OUT endpoint.** Bulk OUT can be left halted by an earlier session; clear the halt before RUN_COMMAND or
  the write fails with an I/O error.
- **Interrupted RUN_COMMAND wedges the daemon.** If the control transfer of request 18 goes out but the JSON never
  follows, the camera waits for it and every later request times out. Either send the expected JSON, or port-reset
  the device (like unplugging; storage is untouched).
- **Oversized parameters.** Parameters 18 and 23 reply with more than 1056 bytes; afterwards requests time out
  until the device is reset.

## Storage layout

```
/events/<bucket>/event_<serial>_<seq>_<YYYYMMDDTHHMMSS>Z.<ext>
/fw/current_firmware.bin, /fw/firmware_upgrade/
/logs/  /calib/  /manifest.json (written by the old uploader)
```

- `<bucket>` is a 10-digit folder holding 100 sequence numbers (`0000056900` holds 56900–56999).
- `<seq>` is a 10-digit capture sequence number; `<serial>` is the 12-hex-digit serial; the timestamp is the
  camera clock in UTC.
- Sequence numbers can be skipped: the camera discards some captures (too dark, lying still).
- If the battery runs completely flat the clock resets to 2000-01-01 and later captures carry year-2000
  timestamps until the clock is set again (a `time.json` event with `"cause": "LostRTC"` records it).

| Extension | Content |
|---|---|
| `.jpg` | 3264 × 2448 JPEG with EXIF orientation |
| `.mp4` | H.264 1080 × 1920 (portrait), 30 fps, AAC mono |
| `.meta.json` | per-capture metadata, see below |
| `.snap.bin` | 64 KiB raw GNSS signal snapshot (not a position; needs offline processing) |
| `.time.json` | clock change: `{"previous", "updated", "cause": "LostRTC" \| "Update"}` |
| `.wscan.json` | Wi-Fi scan: nearby access points (BSSID, level, frequency) |
| `.linux.log` | short camera log lines |

### meta.json

| Field | Meaning |
|---|---|
| `type` | `Photo` or `Video` |
| `trigger` | `RTC` (timer) or `Double-tap` (any tap) |
| `state_of_charge`, `voltage` | battery percent and millivolts at capture time |
| `acc_data`, `mag_data` | accelerometer samples (`now`, `samples`, `std`); magnetometer reads a constant 100 on tested hardware |
| `aec_gain`, `aec_exp`, `awb_gain`, `avg_win`, `avg_readout`, `light_meter`, `too_dark` | exposure / white balance data |
| `image_seq`, `sess_seq` | sequence numbers |
| `fw_version`, `system_version`, `hw_rev` | software / hardware versions |
| `video_is_rotated`, `video_samples` | videos only: rotation and accelerometer samples per second |

The reported state of charge is not reliable on an aged battery: on the test camera it dropped from about 40 % to
0 % in one step when the voltage reached ~3.1–3.3 V.
