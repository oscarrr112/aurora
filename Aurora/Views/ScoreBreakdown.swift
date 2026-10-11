import SwiftUI

/// 今晚最好的那个小时，评分拆成五个相乘的因素
struct ScoreBreakdown: View {
    @Environment(AppModel.self) private var model
    let hours: [HourOutlook]

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

    var body: some View {
        if let best = hours.max(by: { $0.score < $1.score }), best.kp != nil {
            let score = Int(best.score)
            Card(title: score < 40 ? "为什么只有 \(score) 分" : "\(score) 分怎么来的") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(factors(best)) { row($0) }
                }
            }
        }
    }

    private func row(_ f: Factor) -> some View {
        let color: Color = f.value >= 0.8 ? Palette.aurora : f.value >= 0.5 ? .yellow : .orange

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: f.icon).foregroundStyle(.secondary).frame(width: 18)
                Text(f.label)
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
}
