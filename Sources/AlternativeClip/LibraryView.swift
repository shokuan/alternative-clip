import SwiftUI
import AVKit

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter = Filter.all
    @State private var tileSize: Double = 150

    enum Filter: String, CaseIterable {
        case all, photos, videos
        var title: String {
            switch self {
            case .all: return String(localized: "すべて")
            case .photos: return String(localized: "filter.photos", defaultValue: "写真")
            case .videos: return String(localized: "filter.videos", defaultValue: "動画")
            }
        }
    }

    private var day: String? { model.libraryDay }

    private var captures: [Capture] {
        let caps = model.libraryDays.first { $0.day == day }?.captures ?? []
        switch filter {
        case .all: return caps
        case .photos: return caps.filter { !$0.isVideo }
        case .videos: return caps.filter { $0.isVideo }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            DayList()
                .frame(width: 210)
            Divider()
            grid
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            if model.librarySelection != nil {
                Divider()
                Detail(capture: model.librarySelection)
                    .frame(width: 360)
                    .overlay(alignment: .topTrailing) {
                        Button { model.librarySelection = nil } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).padding(8)
                            .help("閉じる")
                    }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("表示", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Slider(value: $tileSize, in: 100...280) { Text("サイズ") }
                    .frame(width: 110)
                    .help("サムネイルの大きさ")
                Button {
                    NSWorkspace.shared.open(day.map { LibraryStore.root.appendingPathComponent($0) } ?? LibraryStore.root)
                } label: { Label("Finderで開く", systemImage: "folder") }
                    .help("この日のフォルダをFinderで開く")
            }
        }
        .onAppear { if day == nil { model.libraryDay = model.libraryDays.first?.day } }
        .onChange(of: model.libraryDays.map(\.day)) { _, days in if day == nil || !days.contains(day!) { model.libraryDay = days.first } }
        .onChange(of: model.libraryDay) { _, _ in model.librarySelection = nil }
    }

    @ViewBuilder private var grid: some View {
        if model.libraryDays.isEmpty {
            ContentUnavailableView("まだ何もない", systemImage: "photo.on.rectangle",
                                   description: Text("カメラを繋いで取り込むと、ここに日付ごとに並ぶよ。"))
        } else if captures.isEmpty {
            ContentUnavailableView(day == nil ? String(localized: "日付を選んでね") : String(localized: "この日は\(filter.title)がない"), systemImage: "photo.on.rectangle")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.6), spacing: 6)], spacing: 6) {
                    ForEach(captures) { c in
                        Thumb(capture: c, selected: c == model.librarySelection)
                            .onTapGesture { model.librarySelection = c }
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(c.media) }
                    }
                }
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.25))
        }
    }
}

/// Days with captures, newest first, with photo / video counts.
struct DayList: View {
    @EnvironmentObject var model: AppModel

    private static let parse: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let year: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("y"); return f
    }()
    private static let show: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMdEEE"); return f
    }()

    private var byYear: [(year: String, days: [(day: String, captures: [Capture])])] {
        var out: [(String, [(day: String, captures: [Capture])])] = []
        for d in model.libraryDays {
            let y = Self.isUnknown(d.day) ? String(localized: "日付不明") : Self.parse.date(from: d.day).map(Self.year.string) ?? String(d.day.prefix(4))
            if out.last?.0 == y { out[out.count - 1].1.append(d) } else { out.append((y, [d])) }
        }
        return out.map { (year: $0.0, days: $0.1) }
    }

    static func isUnknown(_ day: String) -> Bool { day.hasPrefix("2000-") }

    var body: some View {
        List(selection: $model.libraryDay) {
            ForEach(byYear, id: \.year) { group in
                Section(group.year) {
                    ForEach(group.days, id: \.day) { d in
                        row(d).tag(d.day)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ d: (day: String, captures: [Capture])) -> some View {
        let videos = d.captures.filter(\.isVideo).count
        let photos = d.captures.count - videos
        return VStack(alignment: .leading, spacing: 2) {
            if Self.isUnknown(d.day) {
                Text("時計リセット中に撮影")
            } else {
                Text(verbatim: Self.parse.date(from: d.day).map(Self.show.string) ?? d.day)
            }
            HStack(spacing: 8) {
                if photos > 0 { Label("\(photos)", systemImage: "photo") }
                if videos > 0 { Label("\(videos)", systemImage: "video") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 2)
    }
}

struct Thumb: View {
    let capture: Capture
    let selected: Bool
    @State private var image: NSImage?

    private static let time: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()

    var body: some View {
        Color.black.opacity(0.85)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    if capture.isVideo { Image(systemName: "play.fill") }
                    Text(capture.validTime ? Self.time.string(from: capture.time) : "#\(capture.id)")
                }
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .padding(5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
            .contentShape(Rectangle())
            .task(id: capture.media) {
                Thumbnails.shared.image(for: capture.media, isVideo: capture.isVideo) { image = $0 }
            }
    }
}

struct Detail: View {
    let capture: Capture?
    @State private var player: AVPlayer?
    @State private var image: NSImage?

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("yMMMdEEEjmmss"); return f
    }()
    private static let rows: [(key: String, label: LocalizedStringKey)] = [
        ("type", "種類"), ("trigger", "きっかけ"), ("state_of_charge", "電池残量"), ("voltage", "電池電圧"),
        ("too_dark", "明るさ判定"), ("light_meter", "明るさ"), ("aec_gain", "ゲイン"), ("aec_exp", "露光"),
        ("image_seq", "連番"), ("fw_version", "ファーム"), ("hw_rev", "ハードウェア"),
    ]

    var body: some View {
        if let c = capture {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Group {
                        if c.isVideo {
                            PlayerView(player: player)
                                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                        } else if let image {
                            Image(nsImage: image).resizable().scaledToFit()
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(c.media) }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: 460)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        (c.validTime ? Text(verbatim: Self.time.string(from: c.time)) : Text("日付不明")).font(.headline)
                        Text(verbatim: c.media.lastPathComponent).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }

                    let meta = LibraryStore.meta(c.meta)
                    if !meta.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                            ForEach(Self.rows.filter { meta[$0.key] != nil }, id: \.key) { r in
                                GridRow {
                                    Text(r.label).foregroundStyle(.secondary)
                                    Text(verbatim: Self.format(r.key, meta[r.key]!)).textSelection(.enabled)
                                }
                            }
                        }
                        .font(.callout)
                    }

                    HStack {
                        Button { NSWorkspace.shared.open(c.media) } label: { Label("開く", systemImage: "arrow.up.forward.app") }
                        Button { NSWorkspace.shared.activateFileViewerSelecting([c.media]) } label: { Label("Finderで表示", systemImage: "folder") }
                    }
                }
                .padding(14)
            }
            .onAppear { load(c) }
            .onChange(of: c) { _, n in load(n) }
            .onDisappear { player?.pause() }
        } else {
            ContentUnavailableView("選んでね", systemImage: "hand.tap", description: Text("サムネイルをクリックすると、ここに表示されるよ"))
        }
    }

    private func load(_ c: Capture) {
        player?.pause()
        if c.isVideo {
            player = AVPlayer(url: c.media)
            image = nil
        } else {
            player = nil
            image = nil
            // ImageIO applies the EXIF orientation the camera writes; NSImage(contentsOf:) does not.
            Thumbnails.shared.image(for: c.media, isVideo: false, size: 1600) { img in
                if capture == c { image = img }
            }
        }
    }

    static func format(_ key: String, _ v: Any) -> String {
        switch key {
        case "state_of_charge": return "\(v)%"
        case "voltage": return (v as? Int).map { String(format: "%.2f V", Double($0) / 1000) } ?? "\(v)"
        case "too_dark": return (v as? Int) == 1 ? String(localized: "暗すぎ") : "OK"
        case "trigger":
            switch v as? String {
            case "RTC": return String(localized: "タイマー")
            case "Double-tap": return String(localized: "タップ")
            default: return "\(v)"
            }
        case "type":
            switch v as? String {
            case "Photo": return String(localized: "meta.type.photo", defaultValue: "写真")
            case "Video": return String(localized: "meta.type.video", defaultValue: "動画")
            default: return "\(v)"
            }
        case "fw_version": return (v as? String).map { String($0.split(separator: "-").first ?? Substring($0)) } ?? "\(v)"
        default: return "\(v)"
        }
    }
}

/// AppKit's AVPlayerView. (SwiftUI's VideoPlayer crashes on this macOS when loading its metadata.)
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        v.videoGravity = .resizeAspect
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}
