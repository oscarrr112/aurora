import Foundation
import CoreLocation
import Observation

struct Place: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
}

extension Place {
    static let currentID = "current"

    static var presets: [Place] { Spots.destinations }
}

/// UserDefaults 键，后台任务也读这些
enum Prefs {
    static let customPlaces = "customPlaces"
    static let selectedPlace = "selectedPlace"
    static let lastLatitude = "lastLatitude"
    static let lastLongitude = "lastLongitude"
    static let notifyEnabled = "notifyEnabled"
    static let notifyThreshold = "notifyThreshold"
    static let lastNotified = "lastNotified"
    static let travelMode = "travelMode"

    static var threshold: Int {
        let value = UserDefaults.standard.integer(forKey: notifyThreshold)
        return value > 0 ? value : 20
    }
}

enum AppTab: Hashable {
    case tonight, spots, map, wind, settings
}

@MainActor @Observable
final class AppModel {
    var tab: AppTab = .tonight
    private(set) var customPlaces: [Place]
    private(set) var selectedPlaceID: String
    private(set) var currentLocation: CLLocationCoordinate2D?

    private(set) var ovation: OvationGrid?
    private(set) var kp: [KpPoint] = []
    private(set) var wind: [SolarWindSample] = []
    private(set) var clouds: CloudForecast?
    private(set) var isLoading = false
    private(set) var errors: [String] = []
    private(set) var lastUpdated: Date?

    /// 附近候选点（已按今晚评分排序）和热门目的地
    private(set) var nearby: [SpotForecast] = []
    private(set) var destinations: [SpotForecast] = []
    private(set) var isLoadingSpots = false

    /// 出行范围内的具体观测点（已排序）
    private(set) var viewingSpots: [SpotForecast] = []
    private(set) var isLoadingViewing = false
    var travelMode: TravelMode {
        didSet {
            guard travelMode != oldValue else { return }
            UserDefaults.standard.set(travelMode.rawValue, forKey: Prefs.travelMode)
            viewingSpots = []
            Task {
                await refreshViewingSpots(around: activePlace)
                if travelMode == .car, nearby.isEmpty { await refreshSpots(around: activePlace) }
            }
        }
    }

    /// 当前地点的光污染等级，以及朝极光方向的地平线
    private(set) var placeSky: LightZone?
    private(set) var placeHorizon: HorizonView?

    var placeSkyFactor: Double {
        placeSky.map { ViewingCandidate.skyFactor(ground: $0, horizon: placeHorizon) } ?? 1
    }

    var notifyEnabled: Bool {
        didSet { UserDefaults.standard.set(notifyEnabled, forKey: Prefs.notifyEnabled) }
    }
    var notifyThreshold: Int {
        didSet { UserDefaults.standard.set(notifyThreshold, forKey: Prefs.notifyThreshold) }
    }

    @ObservationIgnored private let locator = LocationProvider()
    @ObservationIgnored private let geocoder = CLGeocoder()
    @ObservationIgnored private var placeNames: [String: String] = [:]
    /// 光污染是年度数据，「附近最暗的陆地」算一次就缓存起来
    @ObservationIgnored private var darkSpotCache: [String: DarkSpot?] = [:]
    /// 观测点的光害、地平线、海景都是静态的，同一个地方只算一次；每次刷新只重新拉天气
    @ObservationIgnored private var viewingCache: [String: [ViewingCandidate]] = [:]
    @ObservationIgnored private var horizonCache: [String: HorizonView] = [:]

    init() {
        let defaults = UserDefaults.standard
        customPlaces = defaults.data(forKey: Prefs.customPlaces)
            .flatMap { try? JSONDecoder().decode([Place].self, from: $0) } ?? []
        selectedPlaceID = defaults.string(forKey: Prefs.selectedPlace) ?? Place.currentID
        notifyEnabled = defaults.bool(forKey: Prefs.notifyEnabled)
        notifyThreshold = Prefs.threshold
        travelMode = defaults.string(forKey: Prefs.travelMode).flatMap(TravelMode.init(rawValue:)) ?? .walk

        // 先用上次的定位结果，打开 App 就有东西看
        if selectedPlaceID == Place.currentID,
           let lat = defaults.object(forKey: Prefs.lastLatitude) as? Double,
           let lon = defaults.object(forKey: Prefs.lastLongitude) as? Double {
            currentLocation = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    var allPlaces: [Place] { Place.presets + customPlaces }

    var activePlace: Place? {
        if selectedPlaceID == Place.currentID {
            guard let c = currentLocation else { return nil }
            return Place(id: Place.currentID, name: "当前位置", latitude: c.latitude, longitude: c.longitude)
        }
        return allPlaces.first { $0.id == selectedPlaceID }
    }

    /// 时间按所选地点的当地时区显示
    var timeZone: TimeZone {
        guard let clouds, let place = activePlace,
              abs(clouds.latitude - place.latitude) < 0.01, abs(clouds.longitude - place.longitude) < 0.01
        else { return .current }
        return clouds.timeZone
    }

    // MARK: 地点

    func select(_ id: String) {
        guard id != selectedPlaceID else { return }
        selectedPlaceID = id
        clouds = nil
        nearby = []
        viewingSpots = []
        UserDefaults.standard.set(id, forKey: Prefs.selectedPlace)
        Task { await refresh() }
    }

    func addPlace(name: String, latitude: Double, longitude: Double) {
        let place = Place(id: UUID().uuidString, name: name, latitude: latitude, longitude: longitude)
        customPlaces.append(place)
        saveCustomPlaces()
        select(place.id)
    }

    func removeCustomPlaces(at offsets: IndexSet) {
        let removed = offsets.map { customPlaces[$0].id }
        customPlaces.remove(atOffsets: offsets)
        saveCustomPlaces()
        if removed.contains(selectedPlaceID) { select(Place.currentID) }
    }

    private func saveCustomPlaces() {
        UserDefaults.standard.set(try? JSONEncoder().encode(customPlaces), forKey: Prefs.customPlaces)
    }

    // MARK: 刷新

    func refreshIfStale() async {
        if let lastUpdated, Date.now.timeIntervalSince(lastUpdated) < 5 * 60 { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        var problems: [String] = []

        if selectedPlaceID == Place.currentID {
            do {
                currentLocation = try await locator.currentLocation().coordinate
            } catch {
                problems.append("定位失败：\(error.localizedDescription)")
            }
        }

        let place = activePlace
        if let place {
            UserDefaults.standard.set(place.latitude, forKey: Prefs.lastLatitude)
            UserDefaults.standard.set(place.longitude, forKey: Prefs.lastLongitude)
        }

        async let ovationResult = capture { try await NOAAClient.fetchOvation() }
        async let kpResult = capture { try await NOAAClient.fetchKpForecast() }
        async let windResult = capture { try await NOAAClient.fetchSolarWind() }
        async let cloudResult = fetchClouds(for: place)

        switch await ovationResult {
        case .success(let value): ovation = value
        case .failure(let error): problems.append("极光概率：\(error.localizedDescription)")
        }
        switch await kpResult {
        case .success(let value): kp = value
        case .failure(let error): problems.append("Kp 预报：\(error.localizedDescription)")
        }
        switch await windResult {
        case .success(let value): wind = value
        case .failure(let error): problems.append("太阳风：\(error.localizedDescription)")
        }
        switch await cloudResult {
        case .success(let value): clouds = value
        case .failure(let error): problems.append("云量：\(error.localizedDescription)")
        case nil: break
        }

        errors = problems
        lastUpdated = .now
        if let place {
            placeSky = await LightPollutionStore.shared.zone(latitude: place.latitude, longitude: place.longitude)
            let key = String(format: "%.3f,%.3f", place.latitude, place.longitude)
            if let cached = horizonCache[key] {
                placeHorizon = cached
            } else {
                let horizon = await ViewingSpots.horizon(latitude: place.latitude, longitude: place.longitude)
                placeHorizon = horizon.view
                if horizon.complete { horizonCache[key] = horizon.view }
            }
        } else {
            placeSky = nil
            placeHorizon = nil
        }
        await refreshViewingSpots(around: place)
        await refreshSpots(around: place)
    }

    // MARK: 具体观测点

    private func refreshViewingSpots(around center: Place?) async {
        guard let center else { viewingSpots = []; return }
        let mode = travelMode
        isLoadingViewing = true
        defer { isLoadingViewing = false }

        let key = String(format: "%.3f,%.3f,%@", center.latitude, center.longitude, mode.rawValue)
        let found: [ViewingCandidate]
        if let cached = viewingCache[key] {
            found = cached
        } else {
            let search = await ViewingSpots.find(around: center, mode: mode)
            found = search.spots
            if search.complete { viewingCache[key] = found }
        }
        // 步行范围内天气都一样，直接用当前地点的；远一点的一次请求查完
        var cloudList: [CloudForecast?] = Array(repeating: clouds, count: found.count)
        if mode != .walk, !found.isEmpty,
           let fetched = try? await WeatherClient.fetchClouds(at: found.map { ($0.latitude, $0.longitude) }),
           fetched.count == found.count {
            cloudList = fetched.map(Optional.some)
        }
        guard mode == travelMode, center.id == activePlace?.id else { return }

        let spots = zip(found, cloudList).map { Spots.forecast(for: $0, clouds: $1, kp: kp, ovation: ovation) }
        // 多挑两个，查地名时可能会去掉机场
        viewingSpots = Spots.pickViewing(spots, count: 8, radiusKm: mode.radiusKm)
        await nameViewingSpots()
        viewingSpots = Array(viewingSpots.prefix(6))
    }

    /// 光污染图上找到的暗处没有名字，查一下附近的地标、路名或村名。落在机场里的去掉（又暗又空旷，但进不去）
    private func nameViewingSpots() async {
        var removed: Set<String> = []
        for spot in viewingSpots where spot.place.name.isEmpty {
            let place = spot.place
            let key = String(format: "spot %.3f,%.3f", place.latitude, place.longitude)
            var name = placeNames[key]
            if name == nil {
                let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
                let placemark = try? await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN")).first
                let areas = placemark?.areasOfInterest ?? []
                if areas.contains(where: { $0.contains("机场") || $0.localizedCaseInsensitiveContains("airport") }) {
                    name = "-"
                } else {
                    // 只有一个 areaOfInterest 时一般是整个岛或地区，太笼统
                    let landmark = areas.count >= 2 ? areas.first : nil
                    name = (landmark ?? placemark?.thoroughfare ?? placemark?.subLocality ?? placemark?.locality)
                        .map { "\($0) 附近" } ?? ""
                }
                placeNames[key] = name
            }
            if name == "-" { removed.insert(place.id); continue }
            guard let index = viewingSpots.firstIndex(where: { $0.id == place.id }) else { continue }
            viewingSpots[index].place.name = (name?.isEmpty ?? true) ? "空旷暗处" : name!
        }
        viewingSpots.removeAll { removed.contains($0.id) }
    }

    // MARK: 推荐观测点

    private func refreshSpots(around center: Place?) async {
        isLoadingSpots = true
        defer { isLoadingSpots = false }

        let store = LightPollutionStore.shared
        // 远处的几圈候选点只有开车才用得上
        let candidates = travelMode == .car ? center.map(Spots.nearbyCandidates(around:)) ?? [] : []
        let places = allPlaces
        async let nearbyResult = capture {
            try await WeatherClient.fetchClouds(at: candidates.map { ($0.place.latitude, $0.place.longitude) })
        }
        async let destinationResult = capture {
            try await WeatherClient.fetchClouds(at: places.map { ($0.latitude, $0.longitude) })
        }

        if candidates.isEmpty {
            nearby = []
        } else if case .success(let clouds) = await nearbyResult {
            var spots: [SpotForecast] = []
            for (candidate, cloud) in zip(candidates, clouds) {
                // 海拔为 0 基本是海面，原地除外
                if candidate.distance > 0, let elevation = cloud.elevation, elevation <= 0 { continue }
                var place = candidate.place
                if candidate.distance == 0, let center { place.name = center.name }
                let sky = await store.zone(latitude: place.latitude, longitude: place.longitude)
                spots.append(Spots.forecast(for: place, clouds: cloud, kp: kp, ovation: ovation, sky: sky,
                                            distanceKm: candidate.distance, bearing: candidate.bearing))
            }
            // 排名靠前、但落在村镇里的点，挪到 5 km 内最暗的陆地上（原地不动，留作对比）
            spots = Spots.rankNearby(spots)
            spots = await relocateToDarkness(spots, limit: 10, radiusKm: 5) { ($0.distanceKm ?? 0) > 0 }
            nearby = Spots.rankNearby(spots)
            await nameTopNearbySpots()
        }

        if case .success(let clouds) = await destinationResult {
            var spots: [SpotForecast] = []
            for (place, cloud) in zip(places, clouds) {
                let sky = await store.zone(latitude: place.latitude, longitude: place.longitude)
                spots.append(Spots.forecast(for: place, clouds: cloud, kp: kp, ovation: ovation, sky: sky))
            }
            // 目的地都是城镇，按开车出城 15 km 内最暗的地方算
            spots = await relocateToDarkness(spots, limit: spots.count, radiusKm: 15) { _ in true }
            destinations = spots.sorted { $0.bestScore > $1.bestScore }
        }
    }

    /// 光害在 2b 以上的点，如果半径内有更暗的陆地，就挪过去
    private func relocateToDarkness(_ spots: [SpotForecast], limit: Int, radiusKm: Double,
                                    where include: (SpotForecast) -> Bool) async -> [SpotForecast] {
        let indices = spots.indices.prefix(limit).filter { i in
            include(spots[i]) && (spots[i].sky?.index ?? 0) > 4
        }
        let darkSpots = await darkestLand(near: indices.map { (spots[$0].place.latitude, spots[$0].place.longitude, radiusKm) })
        var result = spots
        for (i, dark) in zip(indices, darkSpots) {
            guard let dark, let sky = spots[i].sky, dark.zone.index < sky.index else { continue }
            result[i] = Spots.relocate(spots[i], to: dark, kp: kp, ovation: ovation)
        }
        return result
    }

    /// 每个点半径内最暗、且在陆地上的位置。海拔查询合并成一次请求
    private func darkestLand(near requests: [(latitude: Double, longitude: Double, radiusKm: Double)]) async -> [DarkSpot?] {
        var results = [DarkSpot?](repeating: nil, count: requests.count)
        var pending: [(index: Int, key: String, candidates: [DarkSpot])] = []

        for (i, request) in requests.enumerated() {
            let key = String(format: "%.3f,%.3f,%.0f", request.latitude, request.longitude, request.radiusKm)
            if let cached = darkSpotCache[key] {
                results[i] = cached
                continue
            }
            let candidates = await LightPollutionStore.shared.darkCandidates(
                latitude: request.latitude, longitude: request.longitude, radiusKm: request.radiusKm, count: 8)
            pending.append((i, key, candidates))
        }

        let coordinates = pending.flatMap { item in item.candidates.map { ($0.latitude, $0.longitude) } }
        guard !coordinates.isEmpty,
              let elevations = try? await WeatherClient.fetchElevations(at: coordinates),
              elevations.count == coordinates.count else { return results }

        var offset = 0
        for item in pending {
            let slice = elevations[offset..<(offset + item.candidates.count)]
            offset += item.candidates.count
            let land = zip(item.candidates, slice).first { $0.1 > 0 }?.0
            results[item.index] = land
            darkSpotCache[item.key] = .some(land)
        }
        return results
    }

    /// 给排名靠前的候选点查个地名（有缓存，避免频繁请求）
    private func nameTopNearbySpots() async {
        for index in nearby.indices.prefix(6) where (nearby[index].distanceKm ?? 0) > 0 {
            let place = nearby[index].place
            let key = String(format: "%.2f,%.2f", place.latitude, place.longitude)
            var name = placeNames[key]
            if name == nil {
                let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
                let placemark = try? await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN")).first
                name = placemark?.locality ?? placemark?.subAdministrativeArea ?? placemark?.name
                placeNames[key] = name ?? ""
            }
            guard let name, !name.isEmpty, index < nearby.count, nearby[index].place.id == place.id else { continue }
            nearby[index].place.name = name
        }
    }

    /// 把推荐点保存为「我的地点」
    func save(_ spot: SpotForecast) {
        addPlace(name: spot.place.name, latitude: spot.place.latitude, longitude: spot.place.longitude)
    }

    private nonisolated func fetchClouds(for place: Place?) async -> Result<CloudForecast, Error>? {
        guard let place else { return nil }
        return await capture { try await WeatherClient.fetchClouds(latitude: place.latitude, longitude: place.longitude) }
    }
}

private func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) } catch { return .failure(error) }
}

// MARK: - 定位

enum LocationError: LocalizedError {
    case denied

    var errorDescription: String? { "没有定位权限，请在系统设置里允许，或改用固定地点" }
}

@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func currentLocation() async throws -> CLLocation {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .denied, .restricted: finish(.failure(LocationError.denied))
            default: manager.requestLocation()
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard continuation != nil else { return }
            switch manager.authorizationStatus {
            case .notDetermined: break
            case .denied, .restricted: finish(.failure(LocationError.denied))
            default: manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            if let location = locations.last { finish(.success(location)) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }
}
