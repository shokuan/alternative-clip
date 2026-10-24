import SwiftUI

struct CameraView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDelete = false
    @State private var showLog = false

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMdjmm"); return f
    }()

    private var shownInfo: Clip2.Info? { model.info ?? model.lastSeen?.info }
    private var shownSettings: Clip2.Settings? { model.settings ?? model.lastSeen?.settings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !model.connected { connectHint }
                HStack(alignment: .top, spacing: 18) {
                    if let i = shownInfo { statusCard(i) }
                    if let s = shownSettings { settingsCard(s) }
                }
                libraryCard
                if model.connected { actions }
                optionsCard
                DisclosureGroup("ログ", isExpanded: $showLog) {
                    ScrollView {
                        Text(model.log.suffix(60).joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 160)
                }
                .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("カメラからファイルを削除する？", isPresented: $confirmDelete) {
            Button("照合して一致したものだけ削除", role: .destructive) { model.verify(deleteMatches: true) }
        } message: {
            Text("カメラの中身をもう一度読み直して、Macのコピーとバイト単位で一致したファイルだけをカメラから消す。Macに無いファイルや一致しないファイルは残る。元に戻せないよ。")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.orange.gradient).frame(width: 56, height: 56)
                Image(systemName: "camera.aperture").font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: shownInfo?.name.isEmpty == false ? shownInfo!.name : "Narrative Clip 2").font(.title2.bold())
                HStack(spacing: 6) {
                    Circle().fill(model.connected ? Color.green : Color.secondary).frame(width: 8, height: 8)
                    if model.connected {
                        Text("USBで接続中")
                    } else if let at = model.lastSeen?.at {
                        Text("未接続・最後に繋いだのは \(Self.dateFormat.string(from: at))")
                    } else {
                        Text("未接続")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.connected {
                Button { model.importNew() } label: { Label("取り込む", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.busy)
            }
        }
    }

    private var connectHint: some View {
        Label {
            Text("カメラをUSBで繋ぐと、自動で取り込みが始まるよ。繋いでから認識されるまで30秒くらいかかることがある。")
        } icon: {
            Image(systemName: "cable.connector")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func card<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
    }

    private func row(_ label: LocalizedStringKey, _ value: some View) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            value
        }
    }

    private func statusCard(_ i: Clip2.Info) -> some View {
        card(model.connected ? "カメラ" : "カメラ（前回の情報）" as LocalizedStringKey) {
            HStack(spacing: 10) {
                Image(systemName: batteryIcon(i.battery, charging: i.isCharging && model.connected))
                    .font(.title).foregroundStyle(i.battery < 20 ? .orange : .green)
                VStack(alignment: .leading) {
                    Text(verbatim: "\(i.battery)%").font(.title2.bold()).monospacedDigit()
                    Group {
                        if !model.connected { Text("最後に見た残量") } else if i.isCharging { Text("充電中") } else { Text("電池") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                if model.connected { row("時計", clockText(i.clock)) }
                row("ファーム", Text(verbatim: i.firmware))
                row("シリアル", Text(verbatim: i.serial).textSelection(.enabled))
                if let f = model.cameraFiles, model.connected {
                    row("カメラ内", Text("\(f.count)件・\(AppModel.mb(f.bytes))"))
                    row("未取り込み", (f.notOnMac == 0 ? Text("なし") : Text("\(f.notOnMac)件")).foregroundStyle(f.notOnMac == 0 ? Color.secondary : Color.orange))
                }
            }
            .font(.callout)
        }
    }

    private func settingsCard(_ s: Clip2.Settings) -> some View {
        card("撮影設定") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                row("定期撮影", Text("\(SettingsView.actionName(s.onTimer))・\(SettingsView.duration(s.interval))ごと"))
                if s.onTimer == "RecordVideo" { row("動画", Text(verbatim: "\(SettingsView.duration(s.videoDuration))・\(s.quality)")) }
                row("トリプルタップ", Text(verbatim: SettingsView.actionName(s.onTripleTap)))
                row("撮影音", s.sound ? Text("オン") : Text("オフ"))
            }
            .font(.callout)
            Button("設定を変える…") { model.pane = .settings }
                .buttonStyle(.link)
        }
    }

    private var libraryCard: some View {
        let all = model.libraryDays.flatMap(\.captures)
        let videos = all.filter(\.isVideo).count
        return card("Macのライブラリ") {
            HStack(spacing: 28) {
                stat(String(localized: "stat.photos", defaultValue: "写真"), "\(all.count - videos)")
                stat(String(localized: "stat.videos", defaultValue: "動画"), "\(videos)")
                stat(String(localized: "stat.days", defaultValue: "日数"), "\(model.libraryDays.filter { !DayList.isUnknown($0.day) }.count)")
                Spacer()
                Button { model.pane = .library } label: { Label("ライブラリを開く", systemImage: "photo.on.rectangle") }
                Button { NSWorkspace.shared.open(LibraryStore.root) } label: { Label("Finder", systemImage: "folder") }
            }
            HStack(spacing: 6) {
                Text("保存先").foregroundStyle(.secondary)
                Text(verbatim: (model.libraryPath as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button("変更…") { model.chooseLibraryFolder() }
                    .disabled(model.busy)
            }
            .font(.callout)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: value).font(.title2.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            Button { model.verify(deleteMatches: false) } label: { Label("照合", systemImage: "checkmark.shield") }
                .help("カメラの中身を読み直して、Macのコピーと一致するか確かめる")
            Button { model.syncClock() } label: { Label("時計を合わせる", systemImage: "clock") }
            Button { model.refresh() } label: { Label("再読み込み", systemImage: "arrow.clockwise") }
            Spacer()
            Button(role: .destructive) { confirmDelete = true } label: { Label("カメラを空ける…", systemImage: "trash") }
        }
        .disabled(model.busy)
    }

    private var optionsCard: some View {
        card("自動処理") {
            Toggle("繋いだら自動で取り込む", isOn: $model.autoImport)
            Toggle("取り込みのあとにカメラの時計をMacに合わせる", isOn: $model.syncClockOnImport)
            Toggle("ログイン時にこのアプリを起動する", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Text("自動取り込みはアプリが起動している間だけ動く。ウィンドウを閉じても、アプリを終了しなければ動き続けるよ。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func clockText(_ d: Date) -> some View {
        let off = Date().timeIntervalSince(d)
        return HStack(spacing: 4) {
            Text(verbatim: Self.dateFormat.string(from: d))
            if abs(off) > 120 { Text("（\(Int(off / 60))分ずれ）").foregroundStyle(.orange) }
        }
    }

    private func batteryIcon(_ p: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch p {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
