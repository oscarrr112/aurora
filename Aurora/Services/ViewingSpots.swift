import Foundation
import MapKit

/// 怎么去观测点：决定搜索半径和路上时间
enum TravelMode: String, CaseIterable, Identifiable {
    case walk, bike, car

    var id: String { rawValue }

    var label: String {
        switch self {
        case .walk: "步行"
        case .bike: "骑车"
        case .car: "开车"
        }
    }

    var icon: String {
        switch self {
        case .walk: "figure.walk"
        case .bike: "bicycle"
        case .car: "car.fill"
        }
    }

    var radiusKm: Double {
        switch self {
        case .walk: 4
        case .bike: 12
        case .car: 50
        }
    }

    /// 平均速度（km/h）
    private var speed: Double {
        switch self {
        case .walk: 4.5
        case .bike: 14
        case .car: 55
        }
    }

    /// 直线距离乘 1.3 估算实际路程
    func durationText(distanceKm: Double) -> String {
        let minutes = Int((distanceKm * 1.3 / speed * 60 / 5).rounded(.up)) * 5
        if minutes < 60 { return "\(label)约 \(max(minutes, 5)) 分钟" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(label)约 \(h) 小时" : "\(label)约 \(h) 小时 \(m) 分"
    }

    var mapsMode: String {
        switch self {
        case .walk: MKLaunchOptionsDirectionsModeWalking
        case .bike: MKLaunchOptionsDirectionsModeCycling
        case .car: MKLaunchOptionsDirectionsModeDriving
        }
    }
}

/// 观测点的类型
enum SpotKind: String {
    case beach, park, nature, camp, marina, viewpoint, lighthouse, hiking, landmark, peak, cape, picnic, dark

    var label: String {
        switch self {
        case .beach: "海滩"
        case .park: "公园"
        case .nature: "自然区"
        case .camp: "营地"
        case .marina: "码头"
        case .viewpoint: "观景点"
        case .lighthouse: "灯塔"
        case .hiking: "步道"
        case .landmark: "地标"
        case .peak: "山顶"
        case .cape: "海角"
        case .picnic: "野餐点"
        case .dark: "暗处"
        }
    }

    var icon: String {
        switch self {
        case .beach: "beach.umbrella"
        case .park: "tree"
        case .nature: "leaf"
        case .camp: "tent"
        case .marina: "sailboat"
        case .viewpoint: "binoculars"
        case .lighthouse: "light.beacon.max"
        case .hiking: "figure.hiking"
        case .landmark: "building.columns"
        case .peak: "mountain.2"
        case .cape: "water.waves"
        case .picnic: "basket"
        case .dark: "moon.stars"
        }
    }

    /// 公园、地标多在城里，同等条件下排后一点
    var preference: Int {
        switch self {
        case .beach, .viewpoint, .lighthouse, .nature, .peak, .cape: 0
        case .camp, .hiking, .marina, .picnic, .dark: 1
        case .park, .landmark: 2
        }
    }
}

/// 朝极光方向看过去的地平线
struct HorizonView {
    /// 极光方向（度，正北为 0）
    let bearing: Double
    /// 那个方向低空的等效光害等级（近处的灯光影响大，远处的城市只剩一圈光晕）
    let glow: LightZone
    /// 那个方向 1–5 km 内是海：没有灯，也没有树和房子挡着
    let seaView: Bool
}

/// 一个具体的观测地点（还没有天气）
struct ViewingCandidate {
    let name: String
    let kind: SpotKind
    let latitude: Double
    let longitude: Double
    let distanceKm: Double
    let bearing: Double
    let ground: LightZone
    let horizon: HorizonView

    var skyFactor: Double { Self.skyFactor(ground: ground, horizon: horizon) }

    /// 光害系数：脚下天空和极光方向地平线取较差的那个；看不到海的扣一点（可能被挡）
    static func skyFactor(ground: LightZone, horizon: HorizonView?) -> Double {
        guard let horizon else { return ground.skyFactor }
        let worst = max(ground.index, horizon.glow.index)
        return LightZone.all[worst].skyFactor * (horizon.seaView ? 1 : 0.96)
    }
}

enum ViewingSpots {
    fileprivate typealias RawSpot = (name: String?, kind: SpotKind, lat: Double, lon: Double)

    /// 在出行范围内找具体的观测点：OpenStreetMap 和苹果地图里有名字的地点，加上光污染图上几块暗的陆地。
    /// 每个点都算一下脚下和极光方向地平线的光害，以及那个方向是不是海。
    /// complete 为 false 表示有请求失败（被限流、没网），结果不要缓存
    static func find(around center: Place, mode: TravelMode) async -> (spots: [ViewingCandidate], complete: Bool) {
        let radius = mode.radiusKm
        let store = LightPollutionStore.shared
        let auroraBearing = Geomag.auroraBearing(latitude: center.latitude, longitude: center.longitude)

        let landResult = await landPoints(around: center, radiusKm: radius)
        let land = landResult ?? []
        let rankDark = { (spot: DarkSpot) in Double(spot.zone.index) + 2 * spot.distanceKm / radius }
        let darkLand = Array(land.sorted { rankDark($0) < rankDark($1) }.prefix(6))

        // 有名字的地点：OpenStreetMap（观景点、海滩、灯塔、自然保护区、营地、山顶…）+ 苹果地图里身边的公园和码头
        async let osm = searchOSM(around: center, radiusKm: radius)
        async let apple = searchAppleNearby(center)
        let (osmSpots, osmComplete) = await osm
        let pois = osmSpots + (await apple)

        var raw: [RawSpot] = []
        for poi in pois where !raw.contains(where: { Forecaster.distanceKm($0.lat, $0.lon, poi.lat, poi.lon) < 0.15 }) {
            raw.append(poi)
        }
        // 附近 400 m 内没有有名字的地点，就用暗处本身
        for spot in darkLand where !raw.contains(where: { Forecaster.distanceKm($0.lat, $0.lon, spot.latitude, spot.longitude) < 0.4 }) {
            raw.append((nil, .dark, spot.latitude, spot.longitude))
        }

        // 粗筛：脚下越暗越好，远一个半径相当于亮 2 级
        var scored: [(item: RawSpot, zone: LightZone, distance: Double, rank: Double)] = []
        for item in raw {
            let distance = Forecaster.distanceKm(center.latitude, center.longitude, item.lat, item.lon)
            guard distance <= radius * 1.1,
                  let zone = await store.zone(latitude: item.lat, longitude: item.lon) else { continue }
            let rank = Double(zone.index) + 2 * distance / radius + Double(item.kind.preference) * 0.3
            scored.append((item, zone, distance, rank))
        }
        scored.sort { $0.rank < $1.rank }
        scored = Array(scored.prefix(30))

        // 一次请求查海拔：极光方向 1.5 km、4 km 处是不是海
        let seaDistances = [1.5, 4.0]
        let coordinates = scored.flatMap { s in
            seaDistances.map { Spots.destination(from: s.item.lat, s.item.lon, distanceKm: $0, bearing: auroraBearing) }
        }
        let elevationResult = try? await WeatherClient.fetchElevations(at: coordinates)
        let elevations = elevationResult ?? []

        var result: [ViewingCandidate] = []
        for (i, s) in scored.enumerated() {
            let checks = (0..<seaDistances.count).compactMap { elevations[safe: i * seaDistances.count + $0] }
            let seaView = !checks.isEmpty && checks.allSatisfy { $0 <= 0 }
            let glow = await horizonGlow(latitude: s.item.lat, longitude: s.item.lon, bearing: auroraBearing)
            result.append(ViewingCandidate(
                name: s.item.name ?? "",
                kind: s.item.kind,
                latitude: s.item.lat,
                longitude: s.item.lon,
                distanceKm: s.distance,
                bearing: bearingDegrees(center.latitude, center.longitude, s.item.lat, s.item.lon),
                ground: s.zone,
                horizon: HorizonView(bearing: auroraBearing, glow: glow, seaView: seaView)
            ))
        }
        return (result, landResult != nil && osmComplete && (elevationResult != nil || coordinates.isEmpty))
    }

    /// 半径内在陆地上的采样点，暗的优先（海面在光污染图上也是黑的，用海拔排除）
    private static func landPoints(around center: Place, radiusKm: Double) async -> [DarkSpot]? {
        let grid = await LightPollutionStore.shared.darkCandidates(
            latitude: center.latitude, longitude: center.longitude, radiusKm: radiusKm, count: 100,
            minSpacingKm: max(radiusKm / 8, 0.5))
        guard let elevations = try? await WeatherClient.fetchElevations(at: grid.map { ($0.latitude, $0.longitude) }),
              elevations.count == grid.count else { return nil }
        return zip(grid, elevations).filter { $0.1 > 0 }.map(\.0)
    }

    /// 某个地点朝极光方向的地平线；complete 为 false 表示海拔没查到
    static func horizon(latitude: Double, longitude: Double) async -> (view: HorizonView, complete: Bool) {
        let bearing = Geomag.auroraBearing(latitude: latitude, longitude: longitude)
        let glow = await horizonGlow(latitude: latitude, longitude: longitude, bearing: bearing)
        let checks = [1.5, 4.0].map { Spots.destination(from: latitude, longitude, distanceKm: $0, bearing: bearing) }
        let elevations = try? await WeatherClient.fetchElevations(at: checks)
        let seaView = elevations.map { !$0.isEmpty && $0.allSatisfy { $0 <= 0 } } ?? false
        return (HorizonView(bearing: bearing, glow: glow, seaView: seaView), elevations != nil)
    }

    /// 朝极光方向 ±25° 采样，近处的灯光按原等级算，每远一倍降 2 级
    static func horizonGlow(latitude: Double, longitude: Double, bearing: Double) async -> LightZone {
        var worst = 0.0
        for offset in [-25.0, -12.0, 0, 12, 25] {
            for distance in [1.0, 2, 4, 8, 15, 25] {
                let (lat, lon) = Spots.destination(from: latitude, longitude, distanceKm: distance, bearing: bearing + offset)
                guard let zone = await LightPollutionStore.shared.zone(latitude: lat, longitude: lon) else { continue }
                worst = max(worst, Double(zone.index) - 2 * log2(distance))
            }
        }
        return LightZone.all[min(max(Int(worst.rounded()), 0), 14)]
    }

    // MARK: OpenStreetMap（Photon 搜索服务，免费、不要 key）

    private static let osmKinds: [String: SpotKind] = [
        "tourism:viewpoint": .viewpoint, "leisure:bird_hide": .viewpoint,
        "natural:beach": .beach, "man_made:lighthouse": .lighthouse,
        "natural:peak": .peak, "natural:cape": .cape,
        "leisure:nature_reserve": .nature,
        "tourism:camp_site": .camp, "tourism:caravan_site": .camp,
        "tourism:picnic_site": .picnic,
    ]

    private struct PhotonResponse: Decodable {
        struct Feature: Decodable {
            struct Geometry: Decodable { let coordinates: [Double] }
            struct Properties: Decodable {
                let name: String?
                let osm_key: String?
                let osm_value: String?
            }
            let geometry: Geometry
            let properties: Properties
        }
        let features: [Feature]
    }

    /// 每次最多返回 50 个，按离中心远近；分两组查，免得自然保护区把观景点挤掉
    private static func searchOSM(around center: Place, radiusKm: Double) async -> (spots: [RawSpot], complete: Bool) {
        let groups = [
            ["tourism:viewpoint", "natural:beach", "man_made:lighthouse", "natural:peak", "natural:cape", "leisure:bird_hide"],
            ["leisure:nature_reserve", "tourism:camp_site", "tourism:caravan_site", "tourism:picnic_site"],
        ]
        var result: [RawSpot] = []
        var complete = true
        for (i, tags) in groups.enumerated() {
            let key = String(format: "osm%d %.3f,%.3f,%.0f", i, center.latitude, center.longitude, radiusKm)
            if let cached = await POICache.shared.get(key) {
                result += cached.map(\.raw)
                continue
            }
            var components = URLComponents(string: "https://photon.komoot.io/reverse")!
            components.queryItems = [
                URLQueryItem(name: "lat", value: String(format: "%.5f", center.latitude)),
                URLQueryItem(name: "lon", value: String(format: "%.5f", center.longitude)),
                URLQueryItem(name: "radius", value: String(format: "%.0f", radiusKm)),
                URLQueryItem(name: "limit", value: "50"),
            ] + tags.map { URLQueryItem(name: "osm_tag", value: $0) }
            guard let data = try? await HTTP.get(components.url!),
                  let response = try? JSONDecoder().decode(PhotonResponse.self, from: data) else {
                complete = false
                continue
            }
            let spots: [RawSpot] = response.features.compactMap { feature in
                let p = feature.properties
                guard let name = p.name, feature.geometry.coordinates.count == 2,
                      let kind = osmKinds["\(p.osm_key ?? ""):\(p.osm_value ?? "")"] else { return nil }
                return (name, kind, feature.geometry.coordinates[1], feature.geometry.coordinates[0])
            }
            await POICache.shared.set(key, spots.map(POICache.Entry.init))
            result += spots
        }
        return (result, complete)
    }

    // MARK: 苹果地图

    private static var categories: [MKPointOfInterestCategory] {
        var list: [MKPointOfInterestCategory] = [.beach, .park, .nationalPark, .campground, .marina]
        if #available(iOS 18.0, macOS 15.0, *) {
            list += [.hiking, .rvPark]
        }
        return list
    }

    private static func kind(of category: MKPointOfInterestCategory?) -> SpotKind {
        switch category {
        case .beach?: return .beach
        case .nationalPark?: return .nature
        case .campground?: return .camp
        case .marina?: return .marina
        default: break
        }
        if #available(iOS 18.0, macOS 15.0, *) {
            switch category {
            case .hiking?: return .hiking
            case .rvPark?: return .camp
            default: break
            }
        }
        return .park
    }

    /// 苹果地图只返回离中心最近的十几个（约 1 km 内），用来补身边的公园、海边步道、码头。
    /// 搜索有频率限制，地点又基本不变，所以缓存在磁盘上
    private static func searchAppleNearby(_ center: Place) async -> [RawSpot] {
        let key = String(format: "apple %.3f,%.3f", center.latitude, center.longitude)
        if let cached = await POICache.shared.get(key) { return cached.map(\.raw) }
        let request = MKLocalPointsOfInterestRequest(
            center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude), radius: 1500)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)
        let items: [MKMapItem]
        do {
            items = try await MKLocalSearch(request: request).start().mapItems
        } catch let error as MKError where error.code == .placemarkNotFound {
            items = []
        } catch {
            return []  // 被限流或没网，这次先跳过，不缓存
        }
        let spots: [RawSpot] = items.map { item in
            let p = item.placemark.coordinate
            return (item.name, kind(of: item.pointOfInterestCategory), p.latitude, p.longitude)
        }
        await POICache.shared.set(key, spots.map(POICache.Entry.init))
        return spots
    }

    static func bearingDegrees(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = Double.pi / 180
        let dLon = (lon2 - lon1) * r
        let y = sin(dLon) * cos(lat2 * r)
        let x = cos(lat1 * r) * sin(lat2 * r) - sin(lat1 * r) * cos(lat2 * r) * cos(dLon)
        return (atan2(y, x) / r + 360).truncatingRemainder(dividingBy: 360)
    }
}

private actor POICache {
    static let shared = POICache()

    struct Entry: Codable {
        let name: String?
        let kind: String
        let latitude: Double
        let longitude: Double

        init(_ spot: ViewingSpots.RawSpot) {
            name = spot.name
            kind = spot.kind.rawValue
            latitude = spot.lat
            longitude = spot.lon
        }

        var raw: ViewingSpots.RawSpot { (name, SpotKind(rawValue: kind) ?? .park, latitude, longitude) }
    }

    private struct Stored: Codable {
        let date: Date
        let entries: [Entry]
    }

    private var store: [String: Stored]?

    private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "poi-cache.json")
    }

    func get(_ key: String) -> [Entry]? {
        load()
        guard let stored = store?[key], Date.now.timeIntervalSince(stored.date) < 30 * 86400 else { return nil }
        return stored.entries
    }

    func set(_ key: String, _ entries: [Entry]) {
        load()
        store?[key] = Stored(date: .now, entries: entries)
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: Self.file) }
    }

    private func load() {
        guard store == nil else { return }
        store = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([String: Stored].self, from: $0) } ?? [:]
    }
}
