import Foundation
import IOKit
import IOUSBHost
import UserNotifications
import SwiftUI
import AppKit
import ServiceManagement

/// Watches for the camera being plugged in / unplugged.
final class DeviceMonitor {
    private var port: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let added: IOServiceMatchingCallback = { ctx, iter in
            let me = Unmanaged<DeviceMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            me.drain(iter); me.onChange(true)
        }
        let removed: IOServiceMatchingCallback = { ctx, iter in
            let me = Unmanaged<DeviceMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            me.drain(iter); me.onChange(false)
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, USBTransport.deviceMatching(), added, ctx, &addedIter)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, USBTransport.deviceMatching(), removed, ctx, &removedIter)
        drain(addedIter)
        drain(removedIter)
    }

    private func drain(_ iter: io_iterator_t) {
        while case let s = IOIteratorNext(iter), s != 0 { IOObjectRelease(s) }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case idle, working(String), progress(String, Double) }

    @Published var connected = USBTransport.isConnected
    @Published var info: Clip2.Info?
    @Published var settings: Clip2.Settings?
    @Published var editing = Clip2.Settings()
    @Published var ranges = Clip2.Ranges()
    @Published var cameraFiles: (count: Int, bytes: Int, notOnMac: Int)?
    @Published var phase: Phase = .idle
    @Published var log: [String] = []
    @Published var lastError: String?
    @Published var libraryDays: [(day: String, captures: [Capture])] = []
    @Published var battery: [BatterySample] = []
    @Published var pane: Pane? = .camera
    @Published var libraryDay: String?
    @Published var librarySelection: Capture?
    /// What we read the last time the camera was connected (shown while it is unplugged).
    @Published var lastSeen: (info: Clip2.Info, settings: Clip2.Settings, at: Date)?
    @AppStorage("autoImport") var autoImport = true
    @AppStorage("syncClock") var syncClockOnImport = true

    private let worker = DispatchQueue(label: "clip.usb", qos: .userInitiated)
    private var monitor: DeviceMonitor?
    private var importedThisConnection = false

    init() {
        monitor = DeviceMonitor { [weak self] up in
            Task { @MainActor in self?.deviceChanged(up) }
        }
        reloadLibrary()
        loadLastSeen()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        if connected { deviceChanged(true) }
        Snapshot.startIfRequested(self)
        if CommandLine.arguments.contains("--enable-login-item") { setLaunchAtLogin(true) }
    }

    var busy: Bool { phase != .idle }

    // MARK: launch at login

    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = String(localized: "ログイン時の起動を設定できなかった: \(error.localizedDescription)")
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        append(status == .enabled ? String(localized: "ログイン時に起動: オン") : status == .requiresApproval ? String(localized: "ログイン時に起動: システム設定で許可が必要") : String(localized: "ログイン時に起動: オフ"))
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    // MARK: device lifecycle

    private func deviceChanged(_ up: Bool) {
        connected = USBTransport.isConnected
        append(connected ? String(localized: "カメラが繋がった") : String(localized: "カメラが外れた"))
        if !connected {
            info = nil; settings = nil; cameraFiles = nil
            importedThisConnection = false
            return
        }
        // Give the camera a moment after enumeration before talking to it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.connected else { return }
            self.refresh { [weak self] in
                guard let self, self.autoImport, !self.importedThisConnection else { return }
                self.importNew(auto: true)
            }
        }
    }

    /// Runs `body` with an open camera on the USB queue, retrying while another process holds it.
    private func withClip<T>(_ label: String, _ body: @escaping (Clip2, @escaping (String, Double?) -> Void) throws -> T,
                             done: @escaping (Result<T, Error>) -> Void) {
        phase = .working(label)
        lastError = nil
        worker.async {
            let report: (String, Double?) -> Void = { msg, frac in
                DispatchQueue.main.async {
                    if let frac { self.phase = .progress(msg, frac) } else { self.phase = .working(msg) }
                }
            }
            var result: Result<T, Error> = .failure(ClipError.notConnected)
            for attempt in 0..<5 {
                do {
                    let clip = try Clip2()
                    result = .success(try body(clip, report))
                    break
                } catch ClipError.busy where attempt < 4 {
                    report(String(localized: "カメラが使用中… 待ってる"), nil)
                    Thread.sleep(forTimeInterval: 3)
                } catch {
                    result = .failure(error)
                    break
                }
            }
            DispatchQueue.main.async {
                self.phase = .idle
                if case .failure(let e) = result { self.lastError = e.localizedDescription; self.append("⚠️ \(e.localizedDescription)") }
                done(result)
            }
        }
    }

    func append(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date())) \(s)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
        Self.writeLogFile(s)
    }

    /// Also keeps ~/Library/Logs/Alternative Clip/app.log so problems can be looked at later.
    nonisolated static func writeLogFile(_ s: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Alternative Clip")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("app.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func refresh(then: (() -> Void)? = nil) {
        withClip(String(localized: "カメラの情報を読み込み中…"), { clip, _ -> (Clip2.Info, Clip2.Settings, Clip2.Ranges, [(path: String, name: String, size: Int)]) in
            (try clip.info(), try clip.settings(), clip.ranges(), try clip.eventFiles())
        }) { [weak self] r in
            guard let self, case .success(let (i, s, rg, files)) = r else { return }
            self.info = i; self.settings = s; self.editing = s; self.ranges = rg
            self.saveLastSeen(i, s)
            self.append("Camera: fw \(i.firmware), battery \(i.battery)%\(i.isCharging ? " (charging)" : ""), timer=\(s.onTimer) every \(s.interval)s, video \(s.videoDuration)s \(s.quality), sound \(s.sound ? "on" : "off"), \(files.count) files on camera")
            let notOnMac = files.filter { f in
                guard let u = LibraryStore.localURL(for: f.name) else { return false }
                return (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) != f.size
            }.count
            self.cameraFiles = (files.count, files.reduce(0) { $0 + $1.size }, notOnMac)
            then?()
            self.runSelfTestIfRequested()
        }
    }

    // MARK: self test (launch with --selftest-verify or --selftest-settings; used to check the app without the UI)

    private var selfTestStep = 0
    private func runSelfTestIfRequested() {
        let args = CommandLine.arguments
        guard settings != nil else { return }
        if args.contains("--selftest-verify"), selfTestStep == 0 {
            selfTestStep = 1
            append("selftest: verify")
            verify(deleteMatches: false)
        } else if args.contains("--selftest-actions"), let s = settings {
            // Changes the double-tap action and back again; each write reboots the camera.
            switch selfTestStep {
            case 0:
                selfTestStep = 1
                append("selftest: double tap \(s.onDoubleTap) -> ShowBatteryStatus")
                editing.onDoubleTap = s.onDoubleTap == "ShowBatteryStatus" ? "None" : "ShowBatteryStatus"; applySettings()
            case 1:
                selfTestStep = 2
                append("selftest: double tap back to None (now \(s.onDoubleTap))")
                editing.onDoubleTap = "None"; applySettings()
            default: break
            }
        } else if args.contains("--selftest-settings"), let s = settings {
            switch selfTestStep {
            case 0:
                selfTestStep = 1
                append("selftest: sound -> \(s.sound ? "off" : "on")")
                editing.sound.toggle(); applySettings()
            case 1:
                selfTestStep = 2
                append("selftest: sound back")
                editing.sound.toggle(); applySettings()
            default: break
            }
        }
    }

    // MARK: import

    func importNew(auto: Bool = false) {
        let sync = syncClockOnImport
        withClip(String(localized: "カメラのファイルを確認中…"), { clip, report -> (Int, Int) in
            let files = try clip.eventFiles()
            let todo = files.filter { f in
                guard let u = LibraryStore.localURL(for: f.name) else { return false }
                return (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) != f.size
            }
            let need = todo.reduce(0) { $0 + $1.size }
            guard Int64(need) < LibraryStore.freeSpace() - 5_000_000_000 else {
                throw ClipError.diskFull
            }
            var ledger: [String] = []
            var done = 0
            defer { LibraryStore.appendLedger(ledger) }
            for (i, f) in todo.enumerated() {
                report(String(localized: "取り込み中 \(i + 1)/\(todo.count)"), need > 0 ? Double(done) / Double(need) : 1)
                var data: Data?
                var lastError: Error?
                for _ in 0..<3 {
                    do { data = try clip.readFile(f.path, expectedSize: f.size); break } catch { lastError = error; Thread.sleep(forTimeInterval: 1) }
                }
                guard let data, let url = LibraryStore.localURL(for: f.name) else { throw lastError ?? ClipError.protocolError(f.name) }
                let e = EventName(f.name)
                try LibraryStore.write(data, to: url, time: (e?.hasValidTime ?? false) ? e?.utc : nil)
                ledger.append("\(LibraryStore.sha256(data))  \(url.deletingLastPathComponent().lastPathComponent)/\(f.name)")
                done += f.size
            }
            if sync { try clip.syncClock() }
            return (todo.count, need)
        }) { [weak self] r in
            guard let self else { return }
            if case .success(let (n, bytes)) = r {
                self.importedThisConnection = true
                let msg = n == 0 ? String(localized: "新しいファイルはなかった") : String(localized: "\(n)ファイル（\(Self.mb(bytes))）を取り込んだ")
                self.append(msg + (sync ? String(localized: "・時計を合わせた") : ""))
                if auto || n > 0 { self.notify(msg) }
                self.reloadLibrary()
                self.refresh()
            }
        }
    }

    /// Re-reads every camera file that has a Mac copy and compares SHA-256. Optionally deletes matches.
    func verify(deleteMatches: Bool) {
        withClip(deleteMatches ? String(localized: "照合して削除中…") : String(localized: "照合中…"), { clip, report -> (ok: Int, bad: Int, missing: Int, deleted: Int) in
            let files = try clip.eventFiles()
            var ok = 0, bad = 0, missing = 0, deleted = 0
            for (i, f) in files.enumerated() {
                report(deleteMatches ? String(localized: "照合して削除 \(i + 1)/\(files.count)") : String(localized: "照合 \(i + 1)/\(files.count)"), Double(i) / Double(max(files.count, 1)))
                guard let url = LibraryStore.localURL(for: f.name), let local = try? Data(contentsOf: url) else { missing += 1; continue }
                let remote = try clip.readFile(f.path, expectedSize: f.size)
                if LibraryStore.sha256(remote) == LibraryStore.sha256(local) {
                    ok += 1
                    if deleteMatches { try clip.deleteFile(f.path); deleted += 1 }
                } else {
                    bad += 1
                }
            }
            return (ok, bad, missing, deleted)
        }) { [weak self] r in
            guard let self, case .success(let s) = r else { return }
            var msg = String(localized: "照合: 一致 \(s.ok)・不一致 \(s.bad)・Macに無い \(s.missing)")
            if deleteMatches { msg += String(localized: "・カメラから削除 \(s.deleted)") }
            self.append(msg)
            self.notify(msg)
            self.refresh()
        }
    }

    // MARK: settings

    func applySettings() {
        guard let old = settings else { return }
        let new = editing
        withClip(String(localized: "設定を書き込み中…"), { clip, _ -> Bool in
            try clip.apply(new, over: old)
        }) { [weak self] r in
            guard let self, case .success(let reboots) = r else { return }
            self.append(reboots ? String(localized: "設定を書き込んだ（カメラが再起動する）") : String(localized: "設定を書き込んだ"))
            if reboots {
                self.settings = nil
                self.phase = .working(String(localized: "カメラの再起動を待ってる…"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    self?.phase = .idle
                    self?.refresh()
                }
            } else {
                self.refresh()
            }
        }
    }

    func syncClock() {
        withClip(String(localized: "時計を合わせてる…"), { clip, _ in try clip.syncClock() }) { [weak self] r in
            if case .success = r { self?.append(String(localized: "時計をMacに合わせた")); self?.refresh() }
        }
    }

    // MARK: last seen state

    private func saveLastSeen(_ i: Clip2.Info, _ s: Clip2.Settings) {
        lastSeen = (i, s, Date())
        let enc = JSONEncoder()
        UserDefaults.standard.set(try? enc.encode(i), forKey: "lastInfo")
        UserDefaults.standard.set(try? enc.encode(s), forKey: "lastSettings")
        UserDefaults.standard.set(Date(), forKey: "lastSeenAt")
    }

    private func loadLastSeen() {
        let dec = JSONDecoder()
        guard let i = UserDefaults.standard.data(forKey: "lastInfo").flatMap({ try? dec.decode(Clip2.Info.self, from: $0) }),
              let s = UserDefaults.standard.data(forKey: "lastSettings").flatMap({ try? dec.decode(Clip2.Settings.self, from: $0) }),
              let at = UserDefaults.standard.object(forKey: "lastSeenAt") as? Date else { return }
        lastSeen = (i, s, at)
    }

    // MARK: library

    @Published var libraryPath = LibraryStore.root.path

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = LibraryStore.root
        panel.prompt = String(localized: "このフォルダにする")
        panel.message = String(localized: "取り込んだ写真と動画を保存するフォルダを選んでね")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "libraryPath")
        libraryPath = url.path
        librarySelection = nil
        append(String(localized: "保存先を変更: \(url.path)"))
        reloadLibrary()
        if connected { refresh() }
    }

    func reloadLibrary() {
        DispatchQueue.global(qos: .userInitiated).async {
            let days = LibraryStore.scan()
            let bat = LibraryStore.batteryHistory()
            DispatchQueue.main.async {
                self.libraryDays = days
                self.battery = bat
            }
        }
    }

    private func notify(_ text: String) {
        let c = UNMutableNotificationContent()
        c.title = "Alternative Clip"
        c.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    static func mb(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
