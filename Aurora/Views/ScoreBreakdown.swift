import SwiftUI

/// 今晚最好的那个小时，评分拆成五个相乘的因素，标出主要扣分的那项
struct ScoreBreakdown: View {
    @Environment(AppModel.self) private var model
    let hours: [HourOutlook]
    let tz: TimeZone

    private struct Factor: Identifiable {
        enum Key: String { case aurora, dark, clear, moon, light }
        let key: Key
        let icon: String
        let label: String
        let value: Double
        let text: String
        var models: [CloudForecast.ModelCloud] = []
        var id: Key { key }
    }

    private static let names: [Factor.Key: String] = [
        .aurora: "极光不够强", .dark: "天不够黑", .clear: "云", .moon: "月光", .light: "光害",
    ]

    var body: some View {
        if let best = hours.max(by: { $0.score < $1.score }), best.kp != nil {
            let list = factors(best)
            let main = list.min { $0.value < $1.value }!
            let score = Int(best.score)

            Card(title: score < 40 ? "为什么只有 \(score) 分" : "\(score) 分怎么来的") {
                Text("\(Fmt.time(best.time, tz)) 最好 · 下面几项相乘")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, -6)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(list) { factor in
                        row(factor, main: main)
                    }
                }

                let notes = notes(best: best, list: list)
                if !notes.isEmpty {
                    Divider().overlay(.white.opacity(0.1))
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(notes, id: \.self) { Text($0) }
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private func row(_ f: Factor, main: Factor) -> some View {
        let isMain = f.key == main.key && f.value < 0.9
        // 和主要原因差不多的也标出来，免得以为只有一项在扣分
        let isAlso = !isMain && f.value < 0.8 && f.value - main.value < 0.1
        let color: Color = f.value >= 0.8 ? Palette.aurora : f.value >= 0.5 ? .yellow : .orange

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: f.icon).foregroundStyle(.secondary).frame(width: 18)
                Text(f.label).fontWeight(isMain ? .bold : .regular)
                if isMain || isAlso {
                    Text(isMain ? "主要原因" : "也在扣分")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(isMain ? Color.orange : Color.yellow.opacity(0.85), in: Capsule())
                }
                Spacer()
                Text("\(Int((f.value * 100).rounded()))%").bold().monospacedDigit().foregroundStyle(color)
            }
            .font(.subheadline)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(color).frame(width: max(proxy.size.width * f.value, 3))
                }
            }
            .frame(height: 5)
            Text(f.text).font(.caption).foregroundStyle(.secondary)
            if !f.models.isEmpty {
                Text(f.models.map { "\($0.label) \(Int($0.effective.rounded()))%" }.joined(separator: "   "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func factors(_ h: HourOutlook) -> [Factor] {
        var list: [Factor] = []

        let auroraText: String
        if let kp = h.kp {
            auroraText = "预计 Kp \(Fmt.kp(kp))，这里要 \(Fmt.kp(h.kpHorizon))"
        } else {
            auroraText = "还没有这个时段的 Kp 预报"
        }
        list.append(Factor(key: .aurora, icon: "bolt", label: "极光强度", value: h.auroraChance, text: auroraText))

        list.append(Factor(key: .dark, icon: "moon.zzz", label: "天黑", value: h.darkness,
                           text: h.darkness >= 1 ? "全黑" : "太阳在地平线下 \(Int(-h.sunAltitude.rounded()))°，还没全黑"))

        var cloudText = "没有云量数据，按晴天算"
        if let c = h.cloudDetail {
            cloudText = "低云 \(Int(c.low.rounded()))% · 中云 \(Int(c.mid.rounded()))% · 高云 \(Int(c.high.rounded()))%（高云薄，打折算）"
        }
        list.append(Factor(key: .clear, icon: "cloud", label: "晴朗", value: 1 - (h.cloud ?? 0) / 100, text: cloudText,
                           models: (h.cloudDetail?.models.count ?? 0) > 1 ? h.cloudDetail!.models : []))

        list.append(Factor(key: .moon, icon: "moonphase.waxing.gibbous", label: "月光", value: h.moon,
                           text: h.moonAltitude <= 0 ? "月亮在地平线下"
                               : "月亮 \(Int(h.moonIllumination * 100))% 亮，高 \(Int(h.moonAltitude.rounded()))°"))

        var lightText = h.light >= 0.995 ? "几乎没有光害" : "光害"
        if let sky = model.placeSky {
            lightText = "头顶 \(sky.name)"
            if let horizon = model.placeHorizon {
                lightText += " · \(Spots.compass(horizon.bearing))方地平线 \(horizon.glow.name)"
            }
            lightText += " \(sky.summary)"
        }
        if h.light > h.skyFactor + 0.005 { lightText += "，极光强时影响小一些" }
        list.append(Factor(key: .light, icon: "lightbulb", label: "光害", value: h.light, text: lightText))
        return list
    }

    /// 几句结论：去掉主要原因能到多少分、模型分歧、整晚的情况
    private func notes(best: HourOutlook, list: [Factor]) -> [String] {
        var notes: [String] = []
        let value = { (key: Factor.Key) in list.first { $0.key == key }!.value }

        let clear = value(.clear)
        if clear < 0.8 && clear > 0 { notes.append("要是天晴，这个时段能到 \(Int(best.score / clear)) 分。") }
        let models = best.cloudDetail?.models.map(\.effective) ?? []
        if models.count > 1, let lo = models.min(), let hi = models.max(), hi - lo >= 40 {
            notes.append("\(models.count) 个天气模型的云量差了 \(Int(hi - lo))%，分歧很大，评分按平均算。出门前看一眼窗外或卫星云图。")
        }
        let light = value(.light)
        if light < 0.85 { notes.append("去没有光害的地方能到 \(Int(best.score / light)) 分，见「去哪看」。") }
        if value(.aurora) < 0.5 {
            let maxKp = hours.compactMap(\.kp).max() ?? 0
            notes.append("这里要 Kp \(Fmt.kp(best.kpHorizon)) 才能在低空看到，今晚预报最高只有 \(Fmt.kp(maxKp))。")
        }
        // 整晚每个小时卡在哪个因素上
        var counts: [Factor.Key: Int] = [:]
        for h in hours {
            if let worst = factors(h).min(by: { $0.value < $1.value }), worst.value < 0.6 {
                counts[worst.key, default: 0] += 1
            }
        }
        if let top = counts.max(by: { $0.value < $1.value }), Double(top.value) >= Double(hours.count) / 2 {
            notes.append("整晚 \(hours.count) 个小时里，有 \(top.value) 个小时主要卡在\(Self.names[top.key]!)上。")
        }
        return notes
    }
}
