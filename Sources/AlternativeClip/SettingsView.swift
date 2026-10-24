import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    static func actionName(_ a: String) -> String {
        switch a {
        case "None": return String(localized: "なにもしない")
        case "TakePicture": return String(localized: "写真")
        case "RecordVideo": return String(localized: "動画")
        case "TakePictureBurst": return String(localized: "連写")
        case "ShowBatteryStatus": return String(localized: "電池残量を表示")
        default: return a
        }
    }

    var body: some View {
        Group {
            if !model.connected {
                if model.lastSeen != nil {
                    offline
                } else {
                    ContentUnavailableView("カメラが繋がってない", systemImage: "cable.connector.slash",
                                           description: Text("設定を見たり変えたりするには、カメラをUSBで繋いでね。"))
                }
            } else if model.settings == nil {
                ProgressView("設定を読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }
        }
    }

    /// Read-only view of the settings read the last time the camera was connected.
    private var offline: some View {
        Form {
            Section {
                Label("カメラが繋がってないから、前回読み込んだ設定を表示してる。変えるにはUSBで繋いでね。", systemImage: "cable.connector.slash")
                    .foregroundStyle(.secondary)
            }
            if let s = model.lastSeen?.settings {
                Section("撮影の動作") {
                    LabeledContent("定期撮影（タイマー）", value: Self.actionName(s.onTimer))
                    LabeledContent("ダブルタップ", value: Self.actionName(s.onDoubleTap))
                    LabeledContent("トリプルタップ", value: Self.actionName(s.onTripleTap))
                }
                Section("タイミング") {
                    LabeledContent("撮影間隔", value: Self.duration(s.interval))
                    LabeledContent("タイマー動画の長さ", value: Self.duration(s.videoDuration))
                    LabeledContent("タップ動画の長さ", value: Self.duration(s.tapVideoDuration))
                }
                Section("動画と音") {
                    LabeledContent("画質", value: s.quality)
                    LabeledContent("撮影音", value: s.sound ? String(localized: "オン") : String(localized: "オフ"))
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    private var form: some View {
        Form {
            Section("撮影の動作") {
                actionPicker("定期撮影（タイマー）", $model.editing.onTimer)
                actionPicker("ダブルタップ", $model.editing.onDoubleTap)
                actionPicker("トリプルタップ", $model.editing.onTripleTap)
            }
            Section("タイミング") {
                LabeledContent("撮影間隔") {
                    HStack {
                        Slider(value: intBinding($model.editing.interval), in: Double(model.ranges.interval.lowerBound)...Double(model.ranges.interval.upperBound), step: 10)
                            .frame(width: 260)
                        Text(verbatim: Self.duration(model.editing.interval)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                }
                Stepper("タイマー動画の長さ: \(model.editing.videoDuration)秒", value: $model.editing.videoDuration, in: model.ranges.videoDuration)
                Stepper("タップ動画の長さ: \(model.editing.tapVideoDuration)秒", value: $model.editing.tapVideoDuration, in: model.ranges.videoDuration)
            }
            Section("動画") {
                Picker("画質", selection: $model.editing.quality) {
                    ForEach(model.ranges.qualities, id: \.self) { q in
                        (q == model.ranges.qualities.first ? Text("\(q)（最高）") : Text(verbatim: q)).tag(q)
                    }
                }
            }
            Section("音") {
                Toggle("撮影音（タイマーもタップも共通）", isOn: $model.editing.sound)
            }
            Section {
                HStack {
                    if model.editing != model.settings {
                        Group {
                            if model.editing.onTimer != model.settings?.onTimer || model.editing.onDoubleTap != model.settings?.onDoubleTap || model.editing.onTripleTap != model.settings?.onTripleTap {
                                Text("撮影の動作を変えると、カメラが再起動するよ")
                            } else {
                                Text("まだ書き込んでない変更がある")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("元に戻す") { if let s = model.settings { model.editing = s } }
                        .disabled(model.editing == model.settings)
                    Button("カメラに書き込む") { model.applySettings() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.editing == model.settings || model.busy)
                }
            } footer: {
                Text("ファームウェアの書き換えや初期化はこのアプリからはできないようにしてある。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    private func actionPicker(_ title: LocalizedStringKey, _ value: Binding<String>) -> some View {
        Picker(title, selection: value) {
            ForEach(model.ranges.actions + (model.ranges.actions.contains(value.wrappedValue) ? [] : [value.wrappedValue]), id: \.self) { a in
                Text(verbatim: Self.actionName(a)).tag(a)
            }
        }
    }

    private func intBinding(_ b: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(b.wrappedValue) }, set: { b.wrappedValue = Int($0) })
    }

    static func duration(_ s: Int) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.minute, .second]
        f.unitsStyle = .short
        return f.string(from: TimeInterval(s)) ?? "\(s)s"
    }
}
