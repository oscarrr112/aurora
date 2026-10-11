import Charts
import SwiftUI

struct SolarWindView: View {
    @Environment(AppModel.self) private var model
    @State private var hoursShown = 3

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ErrorBanner(errors: model.errors)
                    if model.wind.isEmpty {
                        ProgressView().padding(.top, 120)
                    } else {
                        latest
                        Picker("范围", selection: $hoursShown) {
                            Text("3 小时").tag(3)
                            Text("6 小时").tag(6)
                            Text("24 小时").tag(24)
                        }
                        .pickerStyle(.segmented)
                        charts
                        guide
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .background(SkyBackground())
            .navigationTitle("太阳风")
            .toolbar { RefreshButton() }
            .refreshable { await model.refresh() }
        }
    }

    // MARK: 最新值

    private var latest: some View {
        let bz = model.wind.last { $0.bz != nil }
        let bt = model.wind.last { $0.bt != nil }?.bt
        let speed = model.wind.last { $0.speed != nil }?.speed
        let density = model.wind.last { $0.density != nil }?.density
        // 最近 30 分钟 Bz 的平均值比单个点更能说明问题
        let recentBz = model.wind.filter { $0.time > .now - 30 * 60 }.compactMap(\.bz)
        let avgBz = recentBz.isEmpty ? nil : recentBz.reduce(0, +) / Double(recentBz.count)

        return VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                metric("Bz", bz?.bz, "nT", "%.1f", bzColor(bz?.bz),
                       avgBz.map { String(format: "30 分钟均值 %.1f", $0) })
                metric("速度", speed, "km/s", "%.0f", speedColor(speed), nil)
                metric("密度", density, "p/cm³", "%.1f", densityColor(density), nil)
                metric("Bt", bt, "nT", "%.1f", .primary, nil)
            }
            if let speed, speed > 0 {
                Text("L1 点离地球约 150 万 km，按当前速度约 \(Int(1_500_000 / speed / 60)) 分钟后到达")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let time = bz?.time {
                Text("数据时间 \(Fmt.time(time, .current))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func metric(_ title: String, _ value: Double?, _ unit: String, _ format: String,
                        _ color: Color, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map { String(format: format, $0) } ?? "–")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            Text(note ?? " ").font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private func bzColor(_ v: Double?) -> Color {
        guard let v else { return .primary }
        return v <= -10 ? .red : v <= -5 ? .orange : v < 0 ? Palette.aurora : .secondary
    }

    private func speedColor(_ v: Double?) -> Color {
        guard let v else { return .primary }
        return v >= 700 ? .red : v >= 500 ? .orange : .primary
    }

    private func densityColor(_ v: Double?) -> Color {
        guard let v else { return .primary }
        return v >= 20 ? .orange : v >= 10 ? .yellow : .primary
    }

    // MARK: 图表

    private var charts: some View {
        let cutoff = Date.now - Double(hoursShown) * 3600
        let samples = model.wind.filter { $0.time > cutoff }

        return VStack(spacing: 16) {
            Card(title: "Bz（向南为负，越负越好）") {
                Chart {
                    RuleMark(y: .value("0", 0)).foregroundStyle(.white.opacity(0.4))
                    ForEach(samples.filter { $0.bz != nil }) { s in
                        LineMark(x: .value("时间", s.time), y: .value("Bz", s.bz!))
                            .foregroundStyle(Palette.aurora)
                            .interpolationMethod(.monotone)
                    }
                }
                .frame(height: 150)
            }
            Card(title: "速度 km/s") {
                Chart(samples.filter { $0.speed != nil }) { s in
                    LineMark(x: .value("时间", s.time), y: .value("速度", s.speed!))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 130)
            }
            Card(title: "密度 p/cm³") {
                Chart(samples.filter { $0.density != nil }) { s in
                    LineMark(x: .value("时间", s.time), y: .value("密度", s.density!))
                        .foregroundStyle(.yellow)
                        .interpolationMethod(.monotone)
                }
                .frame(height: 110)
            }
        }
    }

    private var guide: some View {
        Card(title: "怎么看") {
            VStack(alignment: .leading, spacing: 6) {
                Text("• **Bz 持续为负**最关键：低于 −5 持续 20 分钟以上，极光通常会变强。")
                Text("• **速度**越快能量越大，500 以上不错，700 以上是强烈事件。")
                Text("• **密度**高会让极光更亮、往低纬扩展。")
                Text("• 这些是太阳风到地球前 30–60 分钟的「预警」，比 Kp 反应快。")
            }
            .font(.callout)
        }
    }
}
