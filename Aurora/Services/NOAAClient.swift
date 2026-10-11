import Foundation

enum FetchError: LocalizedError {
    case badStatus(Int)
    case emptyData

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): "服务器返回 \(code)"
        case .emptyData: "没有数据"
        }
    }
}

enum HTTP {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.badStatus(http.statusCode)
        }
        return data
    }
}

/// NOAA 的时间字符串都是 UTC，有的带 Z，有的不带，有的带小数秒
enum UTCDate {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static func parse(_ string: String) -> Date? {
        var s = string.replacingOccurrences(of: " ", with: "T")
        if s.hasSuffix("Z") { s.removeLast() }
        if let dot = s.firstIndex(of: ".") { s = String(s[..<dot]) }
        return formatter.date(from: s)
    }
}

/// NOAA 空间天气预报中心（SWPC）的公开数据
enum NOAAClient {
    private static let base = URL(string: "https://services.swpc.noaa.gov")!

    // MARK: OVATION 极光概率（约 30–90 分钟的临近预报）

    private struct OvationRaw: Decodable {
        let observationTime: String
        let forecastTime: String
        let coordinates: [[Double]]

        enum CodingKeys: String, CodingKey {
            case observationTime = "Observation Time"
            case forecastTime = "Forecast Time"
            case coordinates
        }
    }

    static func fetchOvation() async throws -> OvationGrid {
        let data = try await HTTP.get(base.appending(path: "json/ovation_aurora_latest.json"))
        let raw = try JSONDecoder().decode(OvationRaw.self, from: data)
        var values = [UInt8](repeating: 0, count: 181 * 360)
        for point in raw.coordinates where point.count >= 3 {
            let lon = Int(point[0]), lat = Int(point[1])
            guard (0..<360).contains(lon), (-90...90).contains(lat) else { continue }
            values[(lat + 90) * 360 + lon] = UInt8(min(max(point[2], 0), 100))
        }
        return OvationGrid(
            observationTime: UTCDate.parse(raw.observationTime) ?? .now,
            forecastTime: UTCDate.parse(raw.forecastTime) ?? .now,
            values: values
        )
    }

    // MARK: Kp 指数（过去 7 天实测 + 未来 3 天预报）

    private struct KpRaw: Decodable {
        let time_tag: String
        let kp: Double
        let observed: String
        let noaa_scale: String?
    }

    static func fetchKpForecast() async throws -> [KpPoint] {
        let data = try await HTTP.get(base.appending(path: "products/noaa-planetary-k-index-forecast.json"))
        let rows: [KpRaw]
        if let objects = try? JSONDecoder().decode([KpRaw].self, from: data) {
            rows = objects
        } else {
            // 旧格式：二维数组，第一行是表头
            let table = try JSONDecoder().decode([[String?]].self, from: data)
            rows = table.dropFirst().compactMap { row in
                guard row.count >= 3, let t = row[0], let kp = row[1].flatMap(Double.init), let kind = row[2] else { return nil }
                return KpRaw(time_tag: t, kp: kp, observed: kind, noaa_scale: row.count > 3 ? row[3] : nil)
            }
        }
        return rows.compactMap { row in
            guard let time = UTCDate.parse(row.time_tag) else { return nil }
            return KpPoint(time: time, kp: row.kp, kind: KpPoint.Kind(rawValue: row.observed) ?? .predicted, scale: row.noaa_scale)
        }
        .sorted { $0.time < $1.time }
    }

    // MARK: 实时太阳风（L1 点卫星，过去 24 小时，每分钟一条）

    private struct MagRaw: Decodable {
        let time_tag: String
        let active: Bool?
        let bt: Double?
        let bz_gsm: Double?
    }

    private struct PlasmaRaw: Decodable {
        let time_tag: String
        let active: Bool?
        let proton_speed: Double?
        let proton_density: Double?
    }

    static func fetchSolarWind() async throws -> [SolarWindSample] {
        async let magData = HTTP.get(base.appending(path: "json/rtsw/rtsw_mag_1m.json"))
        async let plasmaData = HTTP.get(base.appending(path: "json/rtsw/rtsw_wind_1m.json"))
        let mag = try JSONDecoder().decode([MagRaw].self, from: try await magData)
        let plasma = try JSONDecoder().decode([PlasmaRaw].self, from: try await plasmaData)

        // 同一分钟会有多颗卫星的数据，只取当前在用（active）的那一颗
        let activeMag = mag.contains { $0.active == true } ? mag.filter { $0.active == true } : mag
        let activePlasma = plasma.contains { $0.active == true } ? plasma.filter { $0.active == true } : plasma

        var byMinute: [Int: SolarWindSample] = [:]
        func minute(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 60) }

        for row in activeMag {
            guard let t = UTCDate.parse(row.time_tag) else { continue }
            let key = minute(t)
            var sample = byMinute[key] ?? SolarWindSample(time: Date(timeIntervalSince1970: Double(key) * 60))
            sample.bz = row.bz_gsm ?? sample.bz
            sample.bt = row.bt ?? sample.bt
            byMinute[key] = sample
        }
        for row in activePlasma {
            guard let t = UTCDate.parse(row.time_tag) else { continue }
            let key = minute(t)
            var sample = byMinute[key] ?? SolarWindSample(time: Date(timeIntervalSince1970: Double(key) * 60))
            sample.speed = row.proton_speed ?? sample.speed
            sample.density = row.proton_density ?? sample.density
            byMinute[key] = sample
        }
        return byMinute.values.sorted { $0.time < $1.time }
    }
}
