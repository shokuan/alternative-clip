import SwiftUI
import Charts

/// A stretch of shooting on one charge: consecutive samples with no big gap and no recharge.
struct Discharge: Identifiable {
    let samples: [BatterySample]
    var id: Int { samples.first?.id ?? 0 }
    var start: Date { samples.first!.time }
    var end: Date { samples.last!.time }
    var hours: Double { end.timeIntervalSince(start) / 3600 }
    var shots: Int { samples.count }
    var drop: Int { (samples.first?.percent ?? 0) - (samples.last?.percent ?? 0) }
    var endedFlat: Bool { (samples.last?.voltage ?? 4) < 3.35 }

    static func split(_ all: [BatterySample]) -> [Discharge] {
        var out: [[BatterySample]] = []
        var cur: [BatterySample] = []
        for s in all {
            if let last = cur.last, s.time.timeIntervalSince(last.time) > 12 * 3600 || s.percent > last.percent + 5 {
                out.append(cur); cur = []
            }
            cur.append(s)
        }
        if !cur.isEmpty { out.append(cur) }
        return out.filter { $0.count >= 3 }.map(Discharge.init)
    }
}

struct BatteryView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedID: Int?

    private var runs: [Discharge] { Discharge.split(model.battery).reversed() }
    private var selected: Discharge? { runs.first { $0.id == selectedID } ?? runs.first }

    private static let df: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MdHHmm"); return f }()

    var body: some View {
        if runs.isEmpty {
            ContentUnavailableView("電池の記録がまだない", systemImage: "battery.0percent",
                                   description: Text("撮影ごとの記録（meta.json）から電池の推移を表示するよ。"))
        } else {
            HSplitView {
                List(runs, selection: $selectedID) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Self.df.string(from: r.start)) 〜 \(Self.df.string(from: r.end))")
                        Text(verbatim: Self.summary(r))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(r.id)
                }
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)

                if let r = selected { chart(r) }
            }
        }
    }

    private func chart(_ r: Discharge) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(Self.df.string(from: r.start)) 〜 \(Self.df.string(from: r.end))").font(.title3.bold())
                HStack(spacing: 24) {
                    stat("撮影時間", Self.hours(r.hours))
                    stat("撮影回数", String(localized: "\(r.shots)回"))
                    stat("残量表示", "\(r.samples.first!.percent)% → \(r.samples.last!.percent)%")
                    stat("電圧", String(format: "%.2fV → %.2fV", r.samples.first!.voltage, r.samples.last!.voltage))
                }
                GroupBox("残量表示（%）") {
                    Chart(r.samples) {
                        LineMark(x: .value("時刻", $0.time), y: .value("残量", $0.percent))
                            .interpolationMethod(.stepEnd)
                    }
                    .chartYScale(domain: 0...100)
                    .frame(height: 200)
                }
                GroupBox("電圧（V）") {
                    Chart(r.samples) {
                        LineMark(x: .value("時刻", $0.time), y: .value("電圧", $0.voltage))
                        RuleMark(y: .value("ほぼ空", 3.3)).foregroundStyle(.red.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    .chartYScale(domain: 3.0...4.3)
                    .frame(height: 200)
                }
                if r.endedFlat, let last = r.samples.last, last.percent > 5 || r.samples.dropLast().last.map({ $0.percent > 20 }) == true {
                    Label("残量表示がまだ残ってるのに電圧が下がりきって止まってる。電池がヘタってて、残量表示が実際より多めに出てる可能性が高いよ。",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text("赤い点線（3.3V）あたりまで下がると、もうすぐ電源が落ちる目安。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    static func hours(_ h: Double) -> String {
        String(localized: "\(h.formatted(.number.precision(.fractionLength(1))))時間")
    }

    static func summary(_ r: Discharge) -> String {
        var s = String(localized: "\(hours(r.hours))・\(r.shots)回・\(r.samples.first!.percent)%→\(r.samples.last!.percent)%")
        if r.endedFlat { s += String(localized: "・電池切れ") }
        return s
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.headline).monospacedDigit()
        }
    }
}
