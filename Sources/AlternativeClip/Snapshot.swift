import AppKit
import SwiftUI

/// `--snapshot DIR`: renders each pane of the main window to DIR/<pane>.png and quits.
/// Used to review the layout without screen-recording permission.
@MainActor
enum Snapshot {
    static func startIfRequested(_ model: AppModel) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let day = args.firstIndex(of: "--day").map { args[$0 + 1] }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if model.lastSeen == nil {
            // Demo values so the offline layouts can be reviewed / screenshotted.
            var i = Clip2.Info(); i.serial = "0123456789ab"; i.firmware = "v1.5.6"; i.hardware = "unknown-black"
            i.name = "My Clip 2"; i.battery = 72; i.totalBoots = 1234
            var s = Clip2.Settings(); s.onTimer = "RecordVideo"; s.interval = 300; s.videoDuration = 10; s.quality = "1080p30"; s.sound = false
            model.lastSeen = (i, s, Date().addingTimeInterval(-3 * 3600))
        }
        // Screenshots show the default folder rather than wherever the demo library lives.
        model.libraryPath = LibraryStore.defaultRoot.path
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            NSApp.windows.first?.setContentSize(NSSize(width: 1280, height: 800))
            let steps: [(String, () -> Void)] = [
                ("camera", { model.pane = .camera }),
                ("library", { model.pane = .library; model.libraryDay = day ?? model.libraryDays.first?.day }),
                ("library-selected", {
                    let caps = model.libraryDays.first { $0.day == model.libraryDay }?.captures ?? []
                    model.librarySelection = caps.dropFirst(caps.count / 2).first
                }),
                ("settings", { model.pane = .settings }),
                ("battery", { model.pane = .battery }),
            ]
            for (name, act) in steps {
                act()
                try? await Task.sleep(for: .seconds(2.5))
                save(dir.appendingPathComponent("\(name).png"))
            }
            NSApp.terminate(nil)
        }
    }

    /// Captures our own window with CGWindowListCreateImage (looked up at runtime: the Swift SDK
    /// marks it unavailable, but it still works for an app's own windows without extra permission).
    static func save(_ url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1 | BestResolution = 8
        guard let cg = fn(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue() else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
