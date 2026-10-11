import Charts
import SwiftUI

/// 去哪看：出行范围内的具体观测点 +（开车时）150 km 内哪里晴 + 热门目的地排行
struct SpotsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let place = model.activePlace {
                        viewingSection(center: place)
                        if model.travelMode == .car {
                            nearbySection(center: place)
                        }
                    }
                    destinationSection
                    Text("评分综合了极光强度、天黑、云量、月光和光污染。光污染数据来自 David Lorenz 的 Light Pollution Atlas 2025（年度卫星数据推算的天顶亮度），色块就是地图集里的分区；地平线一栏是朝极光方向看过去、按远近折算的灯光。地点来自 OpenStreetMap 和苹果地图，「暗处」是光污染图上找到的空地，去之前看一眼是不是私人土地、晚上安不安全。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .background(SkyBackground())
            .navigationTitle("去哪看")
            .toolbar { RefreshButton() }
            .refreshable { await model.refresh() }
        }
    }

    // MARK: 附近观测点

    @ViewBuilder
    private func viewingSection(center: Place) -> some View {
        let mode = model.travelMode
        let bearing = Geomag.auroraBearing(latitude: center.latitude, longitude: center.longitude)
        let direction = Spots.compass(bearing)
        let precise = Spots.preciseDirection(bearing)

        VStack(alignment: .leading, spacing: 8) {
            Text("附近去哪看").font(.title3.bold())
            Picker("出行方式", selection: Binding(get: { model.travelMode }, set: { model.travelMode = $0 })) {
                ForEach(TravelMode.allCases) { mode in
                    Text("\(mode.label) \(Int(mode.radiusKm)) km").tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text("极光出现在\(precise)方向的低空。按脚下和\(direction)方地平线的光害、云量、路程排序，朝海的地方最开阔。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        SpotsMapCard(center: center, spots: model.viewingSpots, mode: mode)

        VStack(spacing: 10) {
            if model.placeSky != nil {
                SpotRow(spot: origin(center), badge: "原地", mode: mode)
            }
            if model.viewingSpots.isEmpty {
                Card {
                    if model.isLoadingViewing || model.isLoading {
                        ProgressView("正在找\(mode.label)能到的地方…").frame(maxWidth: .infinity)
                    } else {
                        Text("\(Int(mode.radiusKm)) km 内没找到合适的地方，换个出行方式试试").foregroundStyle(.secondary)
                    }
                }
            } else {
                ForEach(Array(model.viewingSpots.enumerated()), id: \.element.id) { index, spot in
                    SpotRow(spot: spot, badge: spot.kind?.label, mode: mode, rank: index + 1)
                }
            }
        }
    }

    private func origin(_ center: Place) -> SpotForecast {
        var spot = Spots.forecast(for: center, clouds: model.clouds, kp: model.kp, ovation: model.ovation,
                                  sky: model.placeSky, skyFactor: model.placeSkyFactor, distanceKm: 0, bearing: 0)
        spot.horizon = model.placeHorizon
        return spot
    }

    // MARK: 开车范围

    @ViewBuilder
    private func nearbySection(center: Place) -> some View {
        let better = model.nearby.filter { ($0.distanceKm ?? 0) > 0 }.prefix(5)

        VStack(alignment: .leading, spacing: 4) {
            Text("开远一点哪里晴").font(.title3.bold())
            Text("在「\(center.name)」周围 150 km 内比较了 25 个点的天气（已排除海面）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)

        if model.nearby.isEmpty {
            Card {
                if model.isLoadingSpots || model.isLoading {
                    ProgressView("正在比较附近的天气…").frame(maxWidth: .infinity)
                } else {
                    Text("暂时没有数据，下拉刷新试试").foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(spacing: 10) {
                ForEach(Array(better)) { spot in
                    SpotRow(spot: spot, badge: spot.directionText, mode: .car)
                }
            }
        }
    }

    // MARK: 热门目的地

    @ViewBuilder
    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("热门目的地今晚").font(.title3.bold())
            Text("点一下切换到这个地点 · 时间为各地当地时间 · 光污染按开车出城 15 km 内最暗的地方算")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)

        if model.destinations.isEmpty {
            Card { ProgressView().frame(maxWidth: .infinity) }
        } else {
            VStack(spacing: 10) {
                ForEach(model.destinations) { spot in
                    Button {
                        model.select(spot.id)
                        model.tab = .tonight
                    } label: {
                        SpotRow(spot: spot, badge: nil, mode: nil)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct SpotRow: View {
    @Environment(AppModel.self) private var model
    let spot: SpotForecast
    let badge: String?
    /// 附近的点：怎么过去；热门目的地为 nil
    let mode: TravelMode?
    /// 地图上的序号
    var rank: Int?

    private var canNavigate: Bool { mode != nil && (spot.distanceKm ?? 0) > 0 }

    var body: some View {
        let best = spot.best
        let score = spot.bestScore

        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Palette.score(score).opacity(0.25), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: min(score / 100, 1))
                    .stroke(Palette.score(score), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(score))").font(.headline.monospacedDigit()).foregroundStyle(Palette.score(score))
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let rank {
                        Text("\(rank)")
                            .font(.caption2.weight(.heavy).monospacedDigit())
                            .foregroundStyle(.black)
                            .frame(width: 18, height: 18)
                            .background(Palette.score(score), in: Circle())
                    }
                    if let kind = spot.kind {
                        Image(systemName: kind.icon).font(.caption).foregroundStyle(Palette.aurora)
                    }
                    Text(spot.place.name).font(.headline).lineLimit(1)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.1), in: Capsule())
                            .fixedSize()
                    }
                }
                if let mode, spot.kind != nil, let distance = spot.distanceKm, let bearing = spot.bearing {
                    Text("\(mode.durationText(distanceKm: distance)) · \(Spots.compass(bearing)) \(String(format: distance < 10 ? "%.1f" : "%.0f", distance)) km")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let sky = spot.sky {
                    skyLine(sky)
                }
                Text(detail(best))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // 具体观测点的天气基本一样，曲线省掉，给名字留地方
            if spot.kind == nil {
                sparkline
                    .frame(width: 56, height: 28)
            }

            if canNavigate, let mode {
                Button {
                    Navigation.open(spot.place, mode: mode)
                } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Palette.aurora)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .contextMenu {
            if canNavigate, let mode {
                Button("\(mode.label)导航", systemImage: mode.icon) { Navigation.open(spot.place, mode: mode) }
                Button("保存为我的地点", systemImage: "star") { model.save(spot) }
            } else if mode == nil && spot.shiftKm != nil {
                Button("导航到城外暗处", systemImage: "car") { Navigation.open(spot.place, mode: .car) }
            }
        }
    }

    @ViewBuilder
    private func skyLine(_ sky: LightZone) -> some View {
        HStack(spacing: 4) {
            if let horizon = spot.horizon {
                Text("头顶")
                ZoneChip(zone: sky)
                Text("\(Spots.compass(horizon.bearing))方")
                ZoneChip(zone: horizon.glow)
                if horizon.seaView {
                    Image(systemName: "water.waves").foregroundStyle(.cyan)
                    Text("朝海")
                }
            } else if let original = spot.originalSky, let shift = spot.shiftKm {
                if mode != nil {
                    ZoneChip(zone: sky)
                    Text("挪 \(String(format: "%.1f", shift)) km 避开灯光")
                } else {
                    Text("城区")
                    ZoneChip(zone: original)
                    Image(systemName: "arrow.right").font(.system(size: 8))
                    Text("城外 \(Int(shift.rounded())) km")
                    ZoneChip(zone: sky)
                }
            } else {
                ZoneChip(zone: sky)
                Text(sky.summary)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func detail(_ best: HourOutlook?) -> String {
        guard let best, best.score >= 1 else {
            if spot.hours.isEmpty { return "今晚不会天黑" }
            if (spot.hours.map(\.auroraChance).max() ?? 0) < 0.2 { return "Kp 不够，这里纬度偏低" }
            return "云太多"
        }
        var parts = ["\(Fmt.time(best.time, spot.timeZone)) 最好"]
        if let cloud = best.cloud { parts.append("云 \(Int(cloud))%") }
        if let now = spot.nowVisible, now >= 5 { parts.append("现在 \(now)%") }
        return parts.joined(separator: " · ")
    }

    private var sparkline: some View {
        Chart(spot.hours) { hour in
            AreaMark(x: .value("时间", hour.time), y: .value("评分", hour.score))
                .foregroundStyle(LinearGradient(colors: [Palette.aurora.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("时间", hour.time), y: .value("评分", hour.score))
                .foregroundStyle(Palette.aurora)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .opacity(spot.hours.isEmpty ? 0 : 1)
    }
}
