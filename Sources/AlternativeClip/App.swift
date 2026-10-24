import SwiftUI
import AppKit

@main
struct AlternativeClipApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Running from a bare executable (swift run) still gets a Dock icon and a key window.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Alternative Clip") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("新しいファイルを取り込む") { model.importNew() }
                    .keyboardShortcut("i")
                    .disabled(!model.connected || model.busy)
                Button("ライブラリを再読み込み") { model.reloadLibrary() }
                    .keyboardShortcut("r")
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("すべてを選択") { model.selectAllToken += 1 }
                    .keyboardShortcut("a")
                    .disabled(model.pane != .library)
                Button("ゴミ箱に入れる") { model.pendingDelete = Array(model.selectedCaptures) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.pane != .library || model.selectedCaptures.isEmpty)
            }
        }
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case camera, library, settings, battery
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .camera: return "カメラ"
        case .library: return "ライブラリ"
        case .settings: return "撮影設定"
        case .battery: return "電池"
        }
    }
    var icon: String {
        switch self {
        case .camera: return "camera"
        case .library: return "photo.on.rectangle"
        case .settings: return "slider.horizontal.3"
        case .battery: return "battery.75percent"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $model.pane) { p in
                Label(p.title, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
            .safeAreaInset(edge: .bottom) { ConnectionBadge().padding(10) }
        } detail: {
            VStack(spacing: 0) {
                switch model.pane ?? .camera {
                case .camera: CameraView()
                case .library: LibraryView()
                case .settings: SettingsView()
                case .battery: BatteryView()
                }
                StatusBar()
            }
        }
    }
}

struct ConnectionBadge: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(model.connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
            (model.connected ? Text("接続中") : Text("未接続")).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .idle:
                if let e = model.lastError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(e).lineLimit(1)
                } else {
                    Text(model.log.last ?? "").foregroundStyle(.secondary).lineLimit(1)
                }
            case .working(let s):
                ProgressView().controlSize(.small)
                Text(s)
            case .progress(let s, let f):
                ProgressView(value: f).frame(width: 160)
                Text(s)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
