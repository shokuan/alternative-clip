import Foundation
import CryptoKit
import AVFoundation
import AppKit
import ImageIO

/// File naming used by the camera: event_<serial>_<seq>_<YYYYMMDDTHHMMSS>Z.<ext>
struct EventName {
    let serial: String
    let seq: Int
    let utc: Date
    let ext: String

    private static let regex = try! NSRegularExpression(pattern: #"^event_([0-9a-f]{12})_(\d{10})_(\d{8}T\d{6})Z\.(.+)$"#)
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f
    }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init?(_ name: String) {
        let range = NSRange(name.startIndex..., in: name)
        guard let m = Self.regex.firstMatch(in: name, range: range),
              let serial = Range(m.range(at: 1), in: name), let seq = Range(m.range(at: 2), in: name),
              let ts = Range(m.range(at: 3), in: name), let ext = Range(m.range(at: 4), in: name),
              let date = Self.parser.date(from: String(name[ts])) else { return nil }
        self.serial = String(name[serial])
        self.seq = Int(name[seq]) ?? 0
        self.utc = date
        self.ext = String(name[ext])
    }

    /// The camera clock was reset (battery ran flat) -> timestamps around year 2000 are meaningless.
    var hasValidTime: Bool { Calendar(identifier: .gregorian).component(.year, from: utc) >= 2014 }

    /// Folder name: local date of capture (or the raw filename date when the clock was reset).
    var dayFolder: String {
        if hasValidTime { return Self.dayFormat.string(from: utc) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: utc)
    }
}

/// One capture: a photo or video plus its sidecar files.
struct Capture: Identifiable, Hashable {
    let id: Int            // camera sequence number
    let day: String
    let time: Date
    let validTime: Bool
    let media: URL
    let isVideo: Bool
    let meta: URL?

    static func == (a: Capture, b: Capture) -> Bool { a.id == b.id && a.media == b.media }
    func hash(into h: inout Hasher) { h.combine(id); h.combine(media) }
}

struct BatterySample: Identifiable {
    let id: Int
    let time: Date
    let percent: Int
    let voltage: Double   // volts
    let isVideo: Bool
}

enum LibraryStore {
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Alternative Clip")

    /// Library folder: `--library PATH` on the command line, else the user's choice, else ~/Pictures/Alternative Clip.
    static var root: URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--library"), i + 1 < args.count { return URL(fileURLWithPath: args[i + 1]) }
        if let p = UserDefaults.standard.string(forKey: "libraryPath"), !p.isEmpty { return URL(fileURLWithPath: p) }
        return defaultRoot
    }
    static var ledger: URL { root.appendingPathComponent("sha256.txt") }

    static func localURL(for name: String) -> URL? {
        guard let e = EventName(name) else { return nil }
        return root.appendingPathComponent(e.dayFolder).appendingPathComponent(name)
    }

    /// Scans the library folder. Returns captures grouped by day, newest day first.
    static func scan() -> [(day: String, captures: [Capture])] {
        let fm = FileManager.default
        guard let days = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var result: [(String, [Capture])] = []
        for day in days.sorted(by: >) where day.count == 10 && day.first?.isNumber == true {
            let dir = root.appendingPathComponent(day)
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            let set = Set(files)
            var caps: [Capture] = []
            for f in files where f.hasSuffix(".jpg") || f.hasSuffix(".mp4") {
                guard let e = EventName(f) else { continue }
                let base = String(f.dropLast(4))
                let metaName = base + ".meta.json"
                caps.append(Capture(id: e.seq, day: day, time: e.utc, validTime: e.hasValidTime,
                                    media: dir.appendingPathComponent(f), isVideo: f.hasSuffix(".mp4"),
                                    meta: set.contains(metaName) ? dir.appendingPathComponent(metaName) : nil))
            }
            if !caps.isEmpty { result.append((day, caps.sorted { $0.id < $1.id })) }
        }
        return result
    }

    static func meta(_ url: URL?) -> [String: Any] {
        guard let url, let d = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }

    /// Battery history from every meta.json with a valid timestamp.
    static func batteryHistory() -> [BatterySample] {
        var out: [BatterySample] = []
        for (_, caps) in scan() {
            for c in caps where c.validTime {
                let m = meta(c.meta)
                guard let soc = m["state_of_charge"] as? Int, let mv = m["voltage"] as? Int else { continue }
                out.append(BatterySample(id: c.id, time: c.time, percent: soc, voltage: Double(mv) / 1000, isVideo: c.isVideo))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func write(_ data: Data, to url: URL, time: Date?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("part")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let h = try FileHandle(forWritingTo: tmp)
        try h.write(contentsOf: data)
        try h.synchronize()
        try h.close()
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: tmp, to: url)
        if let time { try? FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: url.path) }
    }

    static func appendLedger(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n") + "\n"
        if let h = try? FileHandle(forWritingTo: ledger) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        } else {
            try? text.write(to: ledger, atomically: true, encoding: .utf8)
        }
    }

    static func freeSpace() -> Int64 {
        let v = try? root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

/// Thumbnails for photos (ImageIO) and videos (first frame), cached in memory.
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSURL, NSImage>()
    private let queue = DispatchQueue(label: "thumbs", qos: .userInitiated, attributes: .concurrent)

    func image(for url: URL, isVideo: Bool, size: CGFloat = 640, completion: @escaping (NSImage?) -> Void) {
        let key = NSURL(string: url.absoluteString + "#\(Int(size))")!
        if let img = cache.object(forKey: key) { completion(img); return }
        queue.async {
            var cg: CGImage?
            if isVideo {
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: size, height: size)
                cg = try? gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
            } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: size,
                ] as CFDictionary)
            }
            let img = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            if let img { self.cache.setObject(img, forKey: key) }
            DispatchQueue.main.async { completion(img) }
        }
    }
}
