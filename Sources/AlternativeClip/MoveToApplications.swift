import AppKit

/// Offers to move the app into /Applications when it's opened from somewhere else
/// (Downloads, a disk image, or the read-only copy macOS runs a downloaded app from).
enum MoveToApplications {
    private static let suppressKey = "moveToApplicationsSuppressed"
    private static let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)

    static func offerIfNeeded() {
        let args = CommandLine.arguments
        guard !args.contains("--snapshot"), !args.contains("--no-move-prompt"),
              !UserDefaults.standard.bool(forKey: suppressKey) else { return }
        let running = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard running.pathExtension == "app", !isInApplications(running) else { return }

        // A downloaded app opened in place runs from a hidden read-only copy; move the original.
        let source = originalURL(ofTranslocated: running) ?? running
        let destination = applications.appendingPathComponent(source.lastPathComponent)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "「アプリケーション」フォルダに移動する？")
        alert.informativeText = String(localized: "アプリケーションフォルダに入れておくと、Launchpad や Spotlight から開けて、ログイン時の起動も確実に動くよ。")
        alert.addButton(withTitle: String(localized: "移動する"))
        alert.addButton(withTitle: String(localized: "移動しない"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "今後表示しない")
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: suppressKey) }
        guard answer == .alertFirstButtonReturn else { return }

        do {
            try move(source, to: destination)
            relaunch(destination)
        } catch {
            let fail = NSAlert()
            fail.alertStyle = .warning
            fail.messageText = String(localized: "移動できなかった")
            fail.informativeText = String(localized: "Finder で「Alternative Clip」をアプリケーションフォルダにドラッグしてね。\n\n\(error.localizedDescription)")
            fail.runModal()
        }
    }

    private static func isInApplications(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == applications.path
    }

    private static func move(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            let replace = NSAlert()
            replace.messageText = String(localized: "アプリケーションフォルダにもう「\(destination.lastPathComponent)」がある")
            replace.informativeText = String(localized: "今あるほうをゴミ箱に入れて、これに置き換える？")
            replace.addButton(withTitle: String(localized: "置き換える"))
            replace.addButton(withTitle: String(localized: "キャンセル"))
            guard replace.runModal() == .alertFirstButtonReturn else { throw CocoaError(.userCancelled) }
            // Quit a copy that's running from there before replacing it.
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            where app.bundleURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() {
                app.terminate()
            }
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        try fm.copyItem(at: source, to: destination)
        // Clear the download quarantine so macOS doesn't keep running it from a read-only copy.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", destination.path]
        try? xattr.run(); xattr.waitUntilExit()
        // The old copy goes to the Trash (it can't be on a read-only disk image; leave it there).
        try? fm.trashItem(at: source, resultingItemURL: nil)
    }

    /// Opens the moved copy once this process has quit.
    private static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? sh.run()
        exit(0)
    }

    /// For an app macOS has "translocated", returns where the user actually put it.
    private static func originalURL(ofTranslocated url: URL) -> URL? {
        guard url.path.contains("/AppTranslocation/"),
              let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(lib, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(url as CFURL, nil)?.takeRetainedValue() as URL?
    }
}
