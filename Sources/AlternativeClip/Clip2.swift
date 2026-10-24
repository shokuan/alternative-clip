import Foundation

/// Narrative Clip 2 protocol (reconstructed from the original uploader and the camera firmware).
///
/// * GET_PARAMETER (0xC0, req 4, wIndex = id) -> b'\0' + value.  Ids follow the firmware's
///   D-Bus property table; 18 and 23 reply with more than 1056 bytes and jam the pipe, never read them.
/// * SET_PARAMETER (0x40, req 5, wIndex = id, data = u32 LE or string) -> "ACK" / "ERR" on bulk IN.
/// * FILE_FROM_DEVICE (req 2), DEL_FILE (req 3), GET_DIRECTORY (req 9): payload = path.
///   Directory entries / file headers are 132-byte records.
/// * RUN_COMMAND (req 18): payload = D-Bus method name, JSON argument on bulk OUT -> 264-byte status.
/// * GET_PROPERTY_AS_JSON (req 19): payload = property name -> 264-byte status + JSON.
/// Firmware upgrade (req 17) and FactoryReset are deliberately not implemented.
final class Clip2 {
    enum Param: UInt16 {
        case manufacturer = 0, model = 1, serial = 2, hardware = 3, firmware = 4, battery = 5
        case interval = 6, uploaderEnabled = 7, clock = 10, totalBoots = 11, eventSequence = 12
        case deviceName = 19, videoDuration = 20, tapVideoDuration = 21, videoQuality = 26, sound = 27
    }

    struct Entry {
        let name: String
        let size: Int
        let isDirectory: Bool
    }

    struct Info: Codable {
        var serial = ""
        var firmware = ""
        var hardware = ""
        var name = ""
        var battery = 0
        var isCharging = false
        var clock = Date(timeIntervalSince1970: 0)
        var totalBoots = 0
    }

    struct Settings: Equatable, Codable {
        var onTimer = "TakePicture"
        var onDoubleTap = "None"
        var onTripleTap = "RecordVideo"
        var interval = 30
        var videoDuration = 10
        var tapVideoDuration = 10
        var quality = "1080p30"
        var sound = true
    }

    struct Ranges {
        var actions: [String] = ["None", "TakePicture", "RecordVideo", "ShowBatteryStatus"]
        var qualities: [String] = ["1080p30"]
        var interval = 10...300
        var videoDuration = 7...30
    }

    private static let recordSize = 132
    private static let sentinel: [UInt8] = [0x00, 0xFF, 0xFF, 0x55, 0xAA, 0xFF, 0xFF, 0x00]

    private var usb: USBTransport
    private var stale = true

    /// Opens the camera. If it doesn't answer (its USB daemon can wedge after an interrupted
    /// command), port-reset it once and reopen; storage is not touched.
    init() throws {
        usb = try USBTransport()
        do {
            _ = try usb.controlIn(request: 4, index: Param.serial.rawValue, length: 1056, timeout: 3)
        } catch ClipError.timeout {
            AppModel.writeLogFile("Camera not responding; USB reset")
            try usb.reset()
            var last: Error = ClipError.notConnected
            for _ in 0..<60 {
                Thread.sleep(forTimeInterval: 0.5)
                do {
                    usb = try USBTransport()
                    _ = try usb.controlIn(request: 4, index: Param.serial.rawValue, length: 1056, timeout: 3)
                    return
                } catch { last = error }
            }
            throw last
        }
    }

    // MARK: parameters

    func param(_ p: Param) throws -> Data {
        let d = try usb.controlIn(request: 4, index: p.rawValue, length: 1056)
        return d.isEmpty ? d : d.dropFirst()
    }

    func paramString(_ p: Param) throws -> String {
        String(decoding: try param(p).prefix { $0 != 0 }, as: UTF8.self)
    }

    func paramUInt(_ p: Param) throws -> Int {
        let d = try param(p)
        guard d.count >= 4 else { return Int(d.first ?? 0) }
        return Int(d.readUInt32LE(at: 0))
    }

    func setParam(_ p: Param, _ value: Int) throws {
        var v = UInt32(value).littleEndian
        try setParam(p, data: Data(bytes: &v, count: 4), shown: "\(value)")
    }

    func setParam(_ p: Param, _ value: String) throws {
        try setParam(p, data: Data(value.utf8), shown: value)
    }

    private func setParam(_ p: Param, data: Data, shown: String) throws {
        try bulk {
            try usb.controlOut(request: 5, index: p.rawValue, data: data)
            Thread.sleep(forTimeInterval: 0.2)
            let reply = String(decoding: try usb.bulkRead(timeout: 5).prefix { $0 != 0 }, as: UTF8.self)
            guard reply == "ACK" else { throw ClipError.rejected("\(p) = \(shown) (\(reply))") }
        }
    }

    // MARK: D-Bus properties and commands

    func property(_ name: String) throws -> Any {
        try bulk {
            try usb.controlOut(request: 19, data: Data(name.utf8))
            var (code, size, message, data) = try readStatus()
            guard code == 0 else { throw ClipError.rejected("\(name): \(message)") }
            while data.count < size {
                let chunk = try usb.bulkRead(timeout: 5)
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            let json = data.prefix(size).prefix { $0 != 0 }
            guard let obj = try JSONSerialization.jsonObject(with: Data(json), options: [.fragmentsAllowed]) as? [String: Any],
                  let value = obj[name] else { throw ClipError.protocolError("bad JSON for \(name)") }
            return value
        }
    }

    func run(_ command: String, json: String) throws {
        try bulk {
            try usb.controlOut(request: 18, data: Data(command.utf8))
            Thread.sleep(forTimeInterval: 0.1)
            try usb.bulkWrite(Data(json.utf8))
            let (code, _, message, _) = try readStatus()
            guard code == 0 else { throw ClipError.rejected("\(command): \(message)") }
        }
    }

    private func readStatus() throws -> (Int32, Int, String, Data) {
        var buf = Data()
        while buf.count < 264 {
            let chunk = try usb.bulkRead(timeout: 5)
            if chunk.isEmpty { continue }
            buf.append(chunk)
        }
        let code = Int32(bitPattern: buf.readUInt32LE(at: 0))
        let size = Int(buf.readUInt32LE(at: 4))
        let message = String(decoding: buf[buf.startIndex + 8 ..< buf.startIndex + 264].prefix { $0 != 0 }, as: UTF8.self)
        return (code, size, message, Data(buf.dropFirst(264)))
    }

    // MARK: high level

    func info() throws -> Info {
        var i = Info()
        i.serial = try paramString(.serial)
        i.firmware = try paramString(.firmware)
        i.hardware = try paramString(.hardware)
        i.name = try paramString(.deviceName)
        let clockData = try param(.clock)
        if clockData.count >= 4 { i.clock = Date(timeIntervalSince1970: TimeInterval(clockData.readUInt32LE(at: 0))) }
        i.totalBoots = try paramUInt(.totalBoots)
        let raw = try param(.battery)
        i.battery = (try? property("StateOfCharge") as? Int) ?? raw.first.map(Int.init) ?? 0
        i.isCharging = (try? property("IsCharging") as? Bool) ?? false
        return i
    }

    func settings() throws -> Settings {
        var s = Settings()
        if let a = try property("ConfiguredActions") as? [String: String] {
            s.onTimer = a["onTimer"] ?? s.onTimer
            s.onDoubleTap = a["onDoubleTap"] ?? s.onDoubleTap
            s.onTripleTap = a["onTripleTap"] ?? s.onTripleTap
        }
        s.interval = try paramUInt(.interval)
        s.videoDuration = try paramUInt(.videoDuration)
        s.tapVideoDuration = try paramUInt(.tapVideoDuration)
        s.quality = try paramString(.videoQuality)
        s.sound = try paramUInt(.sound) != 0
        return s
    }

    func ranges() -> Ranges {
        var r = Ranges()
        guard let info = try? property("ImageSettingsInformation") as? [String: Any] else { return r }
        func values(_ key: String) -> [String]? {
            ((info[key] as? [String: Any])?["values"] as? [String])?.filter { !$0.isEmpty }
        }
        func range(_ key: String) -> ClosedRange<Int>? {
            guard let d = info[key] as? [String: Any], let lo = d["minValue"] as? Int, let hi = d["maxValue"] as? Int else { return nil }
            return lo...hi
        }
        if let a = values("cameraAction") { r.actions = a }
        if let q = values("videoQuality") { r.qualities = q.sorted(by: Self.qualityOrder) }
        if let i = range("timerActionInterval") { r.interval = i }
        if let v = range("videoDuration") { r.videoDuration = v }
        return r
    }

    /// Highest resolution first, then highest frame rate.
    static func qualityOrder(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> (Int, Int) {
            let parts = s.lowercased().split(separator: "p")
            let res = parts.first.map { $0 == "vga" ? 480 : Int($0) ?? 0 } ?? 0
            let fps = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return (res, fps)
        }
        return key(a) > key(b)
    }

    /// Applies only what changed. Returns true if the camera will reboot (ConfigureActions does).
    @discardableResult
    func apply(_ new: Settings, over old: Settings) throws -> Bool {
        if new.interval != old.interval { try setParam(.interval, new.interval) }
        if new.videoDuration != old.videoDuration { try setParam(.videoDuration, new.videoDuration) }
        if new.tapVideoDuration != old.tapVideoDuration { try setParam(.tapVideoDuration, new.tapVideoDuration) }
        if new.quality != old.quality { try setParam(.videoQuality, new.quality) }
        if new.sound != old.sound { try setParam(.sound, new.sound ? 1 : 0) }
        if new.onTimer != old.onTimer || new.onDoubleTap != old.onDoubleTap || new.onTripleTap != old.onTripleTap {
            let json = try JSONSerialization.data(withJSONObject: [
                "onTimer": new.onTimer, "onDoubleTap": new.onDoubleTap, "onTripleTap": new.onTripleTap,
            ], options: [.sortedKeys])
            try run("ConfigureActions", json: String(decoding: json, as: UTF8.self))
            return true
        }
        return false
    }

    func syncClock(_ date: Date = Date()) throws {
        try setParam(.clock, Int(date.timeIntervalSince1970))
    }

    // MARK: files

    func listDirectory(_ path: String) throws -> [Entry] {
        try bulk {
            try usb.controlOut(request: 9, data: Data(path.utf8))
            var buf = Data()
            while true {
                let chunk = try usb.bulkRead(timeout: 15)
                if chunk.isEmpty { continue }
                buf.append(chunk)
                let n = buf.count / Self.recordSize
                if n > 0, Array(buf[buf.startIndex + (n - 1) * Self.recordSize + 8 ..< buf.startIndex + (n - 1) * Self.recordSize + 16]) == Self.sentinel { break }
            }
            var out: [Entry] = []
            for i in 0 ..< buf.count / Self.recordSize {
                let base = buf.startIndex + i * Self.recordSize
                if Array(buf[base + 8 ..< base + 16]) == Self.sentinel { continue }
                let name = String(decoding: buf[base + 8 ..< base + Self.recordSize].prefix { $0 != 0 }, as: UTF8.self)
                if name == "." || name == ".." { continue }
                out.append(Entry(name: name, size: Int(buf.readUInt32LE(at: i * Self.recordSize)), isDirectory: buf[base + 4] == 4))
            }
            return out
        }
    }

    func readFile(_ path: String, expectedSize: Int) throws -> Data {
        try bulk {
            try usb.controlOut(request: 2, data: Data(path.utf8))
            var buf = Data()
            while buf.count < Self.recordSize {
                buf.append(try usb.bulkRead(timeout: 15))
            }
            let size = Int(buf.readUInt32LE(at: 0))
            let name = String(decoding: buf[buf.startIndex + 8 ..< buf.startIndex + Self.recordSize].prefix { $0 != 0 }, as: UTF8.self)
            let base = (path as NSString).lastPathComponent
            guard size == expectedSize, name.isEmpty || name.hasSuffix("/" + base) else {
                throw ClipError.protocolError("header mismatch for \(base): \(name) \(size)")
            }
            var data = Data(buf.dropFirst(Self.recordSize))
            data.reserveCapacity(size)
            var empties = 0
            while data.count < size {
                let chunk = try usb.bulkRead(timeout: 15)
                if chunk.isEmpty {
                    empties += 1
                    if empties > 8 { throw ClipError.protocolError("empty packets on \(base)") }
                    continue
                }
                data.append(chunk)
            }
            guard data.count == size else { throw ClipError.protocolError("size mismatch for \(base)") }
            if size % 512 == 0 { stale = true } // a zero-length packet may follow
            return data
        }
    }

    func deleteFile(_ path: String) throws {
        try bulk {
            try usb.controlOut(request: 3, data: Data(path.utf8))
            Thread.sleep(forTimeInterval: 0.2)
            let reply = String(decoding: try usb.bulkRead(timeout: 10).prefix { $0 != 0 }, as: UTF8.self)
            guard reply == "ACK" else { throw ClipError.rejected("delete \(path)") }
        }
    }

    /// All files under /events, oldest first.
    func eventFiles() throws -> [(path: String, name: String, size: Int)] {
        var out: [(String, String, Int)] = []
        for dir in try listDirectory("/events") where dir.isDirectory && dir.name.count == 10 && Int(dir.name) != nil {
            for f in try listDirectory("/events/\(dir.name)") where !f.isDirectory {
                out.append(("/events/\(dir.name)/\(f.name)", f.name, f.size))
            }
        }
        return out.sorted { $0.1 < $1.1 }.map { (path: $0.0, name: $0.1, size: $0.2) }
    }

    private func bulk<T>(_ body: () throws -> T) throws -> T {
        if stale {
            usb.drain()
            stale = false
        }
        do {
            return try body()
        } catch {
            stale = true
            throw error
        }
    }
}

extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
