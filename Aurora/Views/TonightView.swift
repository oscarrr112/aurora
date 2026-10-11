import Charts
import SwiftUI

struct TonightView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ErrorBanner(errors: model.errors)
                    if let place = model.activePlace {
                        content(for: place)
                    } else if model.isLoading {
                        ProgressView("定位中…").padding(.top, 120)
                    } else {
                        ContentUnavailableView("没有位置", systemImage: "location.slash",
                                               description: Text("请允许定位，或在「设置」里选一个地点"))
                            .padding(.top, 80)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .background(SkyBackground())
            .navigationTitle(model.activePlace?.name ?? "极光预报")
            .toolbar { RefreshButton() }
            .refreshable { await model.refresh() }
        }
    }

    @ViewBuilder
    private func content(for place: Place) -> some View {
        let tz = model.timeZone
        let now = Date.now
        let hours = Forecaster.outlook(latitude: place.latitude, longitude: place.longitude,
                                       kp: model.kp, clouds: model.clouds, skyFactor: model.placeSkyFactor, now: now)
        let mlat = Geomag.magneticLatitude(latitude: place.latitude, longitude: place.longitude)

        NowCard(place: place, now: now, tz: tz)
        TonightSummary(place: place, hours: hours, mlat: mlat, now: now, tz: tz)
        NearbyHint(here: hours.map(\.score).max() ?? 0)
        if !hours.isEmpty {
            HourlyCard(hours: hours, need: Geomag.kpNeeded(magneticLatitude: mlat), tz: tz)
        }
        KpCard(points: model.kp, need: Geomag.kpNeeded(magneticLatitude: mlat), tz: tz)

        if let updated = model.lastUpdated {
            Text("更新于 \(Fmt.time(updated, .current)) · 时间均为\(tz == .current ? "本地" : "当地")时间")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 附近更好的地点

private struct NearbyHint: View {
    @Environment(AppModel.self) private var model
    let here: Double

    var body: some View {
        let mode = model.travelMode
        if let spot = model.viewingSpots.first(where: { ($0.distanceKm ?? 0) >= 0.3 }),
           spot.bestScore >= max(here + 10, 15) {
            hint(icon: mode.icon,
                 title: "\(spot.place.name) 今晚更好",
                 subtitle: "\(mode.durationText(distanceKm: spot.distanceKm ?? 0)) · 评分 \(Int(spot.bestScore))，这里只有 \(Int(here))")
        } else if mode == .car, let best = model.nearby.first, (best.distanceKm ?? 0) > 0,
                  best.bestScore >= max(here + 15, 20) {
            hint(icon: "car.fill",
                 title: "\(best.directionText ?? "") 的 \(best.place.name) 今晚更好",
                 subtitle: "评分 \(Int(best.bestScore))，这里只有 \(Int(here))")
        }
    }

    private func hint(icon: String, title: String, subtitle: String) -> some View {
        Button {
            model.tab = .spots
        } label: {
            HStack {
                Image(systemName: icon).foregroundStyle(Palette.aurora)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding()
            .background(Palette.aurora.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 现在

private struct NowCard: View {
    @Environment(AppModel.self) private var model
    let place: Place
    let now: Date
    let tz: TimeZone

    var body: some View {
        let sun = Astro.sunAltitude(at: now, latitude: place.latitude, longitude: place.longitude)
        let cloud = model.clouds?.hour(near: now)?.total

        Card(title: "现在") {
            if let grid = model.ovation {
                let cast = Forecaster.nowcast(grid: grid, latitude: place.latitude, longitude: place.longitude)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(cast.visible)")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.score(Double(cast.visible) * 1.5))
                    Text("%").font(.title2.bold()).foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("视野内极光概率").font(.subheadline)
                        Text("头顶 \(cast.overhead)%").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(verdict(visible: cast.visible, sun: sun, cloud: cloud))
                    .font(.callout.weight(.medium))
                HStack(spacing: 14) {
                    Label("\(Int(sun.rounded()))°", systemImage: sun > -6 ? "sun.max" : "sun.horizon")
                    if let cloud { Label("\(Int(cloud))%", systemImage: "cloud") }
                    Spacer()
                    Text("模型预测到 \(Fmt.time(grid.forecastTime, tz))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private func verdict(visible: Int, sun: Double, cloud: Double?) -> String {
        if sun > -6 { return "天还亮着，等天黑再说" }
        if let cloud, cloud >= 85 { return "云太厚了（\(Int(cloud))%），基本没戏" }
        switch visible {
        case 50...: return "很有希望，赶紧出门！"
        case 20..<50: return "有机会，去暗处往\(place.latitude >= 0 ? "北" : "南")看"
        case 8..<20: return "可能有微弱极光，相机比肉眼更容易拍到"
        default: return "暂时没有明显极光"
        }
    }
}

// MARK: - 今晚概览

private struct TonightSummary: View {
    @Environment(AppModel.self) private var model
    let place: Place
    let hours: [HourOutlook]
    let mlat: Double
    let now: Date
    let tz: TimeZone

    var body: some View {
        let need = Geomag.kpNeeded(magneticLatitude: mlat)
        let window = Astro.darkWindow(around: now, latitude: place.latitude, longitude: place.longitude)
        let best = hours.max { $0.score < $1.score }
        let maxKp = hours.compactMap(\.kp).max()

        Card(title: "今晚") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                row("moon.zzz", "天黑") {
                    if let window {
                        if window.duration > 30 * 3600 {
                            Text("极夜，全天都黑")
                        } else {
                            Text("\(Fmt.time(window.start, tz)) – \(Fmt.time(window.end, tz))")
                        }
                    } else {
                        Text("今晚不会完全天黑").foregroundStyle(.orange)
                    }
                }
                if let best, best.score >= 1 {
                    row("star", "最佳时段") {
                        Text("\(Fmt.time(best.time, tz)) 起 · 评分 \(Int(best.score))")
                            .foregroundStyle(Palette.score(best.score))
                    }
                }
                if let maxKp {
                    row("bolt", "最高 Kp") {
                        Text(Fmt.kp(maxKp)).foregroundStyle(Palette.kp(maxKp))
                    }
                }
                row("moonphase.waxing.gibbous", "月亮") {
                    Text("亮度 \(Int(Astro.moonIllumination(at: now) * 100))%")
                }
                row("location", "本地门槛") {
                    Text(needText(need))
                }
                row("safari", "看哪边") {
                    let bearing = Geomag.auroraBearing(latitude: place.latitude, longitude: place.longitude)
                    Text(need.overhead > 1 ? "\(Spots.preciseDirection(bearing))的低空，强的时候会升高"
                                           : "\(Spots.preciseDirection(bearing))，强的时候满天都是")
                }
                if let sky = model.placeSky {
                    row("lightbulb", "光污染") {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                ZoneChip(zone: sky)
                                Text("\(sky.summary) · SQM \(String(format: "%.1f", sky.sqm))")
                            }
                            if let horizon = model.placeHorizon {
                                HStack(spacing: 4) {
                                    Text("\(Spots.compass(horizon.bearing))方地平线")
                                    ZoneChip(zone: horizon.glow)
                                    if horizon.seaView { Text("· 朝海，视野开阔") }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .font(.callout)
            Text("磁纬约 \(String(format: "%.1f", abs(mlat)))°。门槛是粗略估算，实际以「现在」的概率为准。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func row<V: View>(_ icon: String, _ title: String, @ViewBuilder value: () -> V) -> some View {
        GridRow {
            Label(title, systemImage: icon).foregroundStyle(.secondary)
            value()
        }
    }

    private func needText(_ need: (overhead: Double, horizon: Double)) -> String {
        if need.horizon > 9 { return "需要超强磁暴（Kp 9+），极少见" }
        if need.overhead <= 0.5 { return "Kp 1 左右就可能在头顶出现" }
        let horizon = need.horizon <= 0 ? "Kp 0 就可能看到" : "地平线 Kp ≥ \(Fmt.kp(need.horizon))"
        let overhead = need.overhead > 9 ? "头顶几乎不可能" : "头顶 Kp ≥ \(Fmt.kp(need.overhead))"
        return "\(horizon) · \(overhead)"
    }
}

// MARK: - 逐小时

private struct HourlyCard: View {
    let hours: [HourOutlook]
    let need: (overhead: Double, horizon: Double)
    let tz: TimeZone

    var body: some View {
        let best = hours.max { $0.score < $1.score }

        Card(title: "逐小时评分") {
            Chart {
                ForEach(hours) { hour in
                    if let cloud = hour.cloud {
                        AreaMark(x: .value("时间", hour.time), yStart: .value("0", 0), yEnd: .value("云量", cloud),
                                 series: .value("类型", "云量"))
                            .foregroundStyle(.gray.opacity(0.22))
                            .interpolationMethod(.monotone)
                    }
                }
                ForEach(hours) { hour in
                    LineMark(x: .value("时间", hour.time), y: .value("极光", hour.auroraChance * 100),
                             series: .value("类型", "极光"))
                        .foregroundStyle(.purple.opacity(0.9))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .interpolationMethod(.monotone)
                }
                ForEach(hours) { hour in
                    AreaMark(x: .value("时间", hour.time), yStart: .value("0", 0), yEnd: .value("评分", hour.score),
                             series: .value("类型", "评分"))
                        .foregroundStyle(LinearGradient(colors: [Palette.aurora.opacity(0.45), Palette.aurora.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("时间", hour.time), y: .value("评分", hour.score),
                             series: .value("类型", "评分线"))
                        .foregroundStyle(Palette.aurora)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .interpolationMethod(.monotone)
                }
                if let best, best.score >= 1 {
                    PointMark(x: .value("时间", best.time), y: .value("评分", best.score))
                        .foregroundStyle(Palette.score(best.score))
                        .symbolSize(70)
                        .annotation(position: .top, spacing: 4) {
                            Text("\(Int(best.score)) 分 · \(Fmt.time(best.time, tz))")
                                .font(.caption.bold())
                                .foregroundStyle(Palette.score(best.score))
                        }
                }
            }
            .chartYScale(domain: 0...110)
            .chartYAxis { AxisMarks(values: [0, 50, 100]) }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                }
            }
            .environment(\.timeZone, tz)
            .frame(height: 170)
            .overlay {
                if (best?.score ?? 0) < 1, let zeroReason {
                    Text(zeroReason)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                }
            }

            HStack(spacing: 14) {
                legendLine(Palette.aurora, "综合评分", dashed: false)
                legendLine(.purple, "极光强度", dashed: true)
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(.gray.opacity(0.4)).frame(width: 14, height: 8)
                    Text("云量")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            DisclosureGroup("逐小时明细") {
                table.padding(.top, 8)
            }
            .font(.callout)
            .tint(.secondary)
        }
    }

    private var zeroReason: String? {
        // Kp 还没加载出来
        guard let maxKp = hours.compactMap(\.kp).max() else { return nil }
        if hours.allSatisfy({ $0.auroraChance == 0 }) {
            return "今晚这里评分为 0\n这里需要 Kp ≥ \(Fmt.kp(need.horizon))，今晚预报最高只有 \(Fmt.kp(maxKp))"
        }
        if hours.allSatisfy({ ($0.cloud ?? 0) >= 98 }) {
            return "今晚这里评分为 0\n整晚都是阴天，可以看看「去哪看」"
        }
        return "今晚这里评分很低"
    }

    private func legendLine(_ color: Color, _ text: String, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            Path { p in p.move(to: CGPoint(x: 0, y: 4)); p.addLine(to: CGPoint(x: 14, y: 4)) }
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
                .frame(width: 14, height: 8)
            Text(text)
        }
    }

    private var table: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("时间").gridColumnAlignment(.leading)
                Text("Kp")
                Text("云量")
                Text("月亮")
                Text("评分")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            ForEach(hours) { hour in
                GridRow {
                    Text(Fmt.time(hour.time, tz)).gridColumnAlignment(.leading)
                    Text(hour.kp.map(Fmt.kp) ?? "–")
                        .foregroundStyle(hour.kp.map(Palette.kp) ?? .secondary)
                    Text(hour.cloud.map { "\(Int($0))%" } ?? "–")
                    Text(hour.moonAltitude > 0 ? "\(Int(hour.moonAltitude))°" : "落")
                        .foregroundStyle(.secondary)
                    Text("\(Int(hour.score))")
                        .bold()
                        .foregroundStyle(Palette.score(hour.score))
                }
                .font(.callout.monospacedDigit())
            }
        }
        .foregroundStyle(.primary)
    }
}

// MARK: - Kp

private struct KpCard: View {
    let points: [KpPoint]
    let need: (overhead: Double, horizon: Double)
    let tz: TimeZone

    /// 线条颜色随 Kp 高度变化：平静绿 → 活跃黄 → G1 橙 → G2 红 → G3+ 紫
    private static let kpGradient = LinearGradient(stops: [
        .init(color: Palette.aurora, location: 0),
        .init(color: Palette.aurora, location: 3.6 / 9),
        .init(color: .yellow, location: 4.5 / 9),
        .init(color: .orange, location: 5.5 / 9),
        .init(color: .red, location: 6.5 / 9),
        .init(color: .purple, location: 7.6 / 9),
    ], startPoint: .bottom, endPoint: .top)

    private static let kpAreaGradient = LinearGradient(stops: [
        .init(color: Palette.aurora.opacity(0.25), location: 0),
        .init(color: Palette.aurora.opacity(0.25), location: 3.6 / 9),
        .init(color: .yellow.opacity(0.25), location: 4.5 / 9),
        .init(color: .orange.opacity(0.25), location: 5.5 / 9),
        .init(color: .red.opacity(0.25), location: 6.5 / 9),
        .init(color: .purple.opacity(0.25), location: 7.6 / 9),
    ], startPoint: .bottom, endPoint: .top)

    var body: some View {
        let now = Date.now
        let shown = points.filter { $0.end > now - 24 * 3600 }
        let current = Forecaster.kp(at: now, in: points)

        Card(title: "Kp 指数（3 天）") {
            if let first = shown.first, let last = shown.last {
                Chart {
                    // 磁暴等级色带
                    RectangleMark(xStart: .value("起", first.time), xEnd: .value("止", last.end),
                                  yStart: .value("G1", 5), yEnd: .value("G3", 7))
                        .foregroundStyle(.orange.opacity(0.07))
                    RectangleMark(xStart: .value("起", first.time), xEnd: .value("止", last.end),
                                  yStart: .value("G3", 7), yEnd: .value("顶", 9))
                        .foregroundStyle(.red.opacity(0.08))
                    // 未来部分加一层浅色表示「预报」
                    RectangleMark(xStart: .value("现在", now), xEnd: .value("止", last.end),
                                  yStart: .value("底", 0), yEnd: .value("顶", 9))
                        .foregroundStyle(.white.opacity(0.035))
                        .annotation(position: .overlay, alignment: .topLeading) {
                            Text("预报").font(.caption2).foregroundStyle(.secondary).padding(4)
                        }

                    ForEach(shown) { p in
                        AreaMark(x: .value("时间", p.time + 5400), yStart: .value("底", 0), yEnd: .value("Kp", p.kp))
                            .foregroundStyle(Self.kpAreaGradient)
                            .alignsMarkStylesWithPlotArea()
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("时间", p.time + 5400), y: .value("Kp", p.kp))
                            .foregroundStyle(Self.kpGradient)
                            .alignsMarkStylesWithPlotArea()
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }

                    if (0...9).contains(need.horizon) {
                        RuleMark(y: .value("门槛", need.horizon))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.white.opacity(0.7))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("本地门槛 \(Fmt.kp(need.horizon))").font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                    RuleMark(x: .value("现在", now))
                        .foregroundStyle(.white.opacity(0.4))
                    if let current {
                        PointMark(x: .value("时间", current.time + 5400), y: .value("Kp", current.kp))
                            .foregroundStyle(Palette.kp(current.kp))
                            .symbolSize(60)
                            .annotation(position: .top) {
                                Text(Fmt.kp(current.kp)).font(.caption.bold()).foregroundStyle(Palette.kp(current.kp))
                            }
                    }
                }
                .chartYScale(domain: 0...9)
                .chartXScale(domain: first.time...last.end)
                .chartYAxis {
                    AxisMarks(values: [0, 3, 5, 7, 9]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text(v == 5 ? "5 G1" : v == 7 ? "7 G3" : "\(v)")
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    }
                }
                .environment(\.timeZone, tz)
                .frame(height: 180)

                Text("Kp 是全球地磁活跃度，0–9 级。5 级以上为磁暴（G1–G5），极光会往低纬扩展。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }
}
