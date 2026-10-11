import Foundation

/// Open-Meteo 云量预报（免费、无需 Key）
enum WeatherClient {
    /// 一起查的几个天气模型：当地最优（北欧是 MET Nordic）、欧洲中心、德国、美国。
    /// 云量预报在模型之间常常差很多，只信一个容易整晚误判，取平均更稳
    static let models: [(id: String, label: String)] = [
        ("best_match", "当地模型"), ("ecmwf_ifs025", "ECMWF"), ("icon_seamless", "ICON"), ("gfs_seamless", "GFS"),
    ]

    /// 有效云量：低云不透光按原值，中云按 9 成，高云（薄卷云，亮的极光能透过来）按 4 成，各层随机重叠
    static func effectiveCloud(low: Double, mid: Double, high: Double) -> Double {
        100 * (1 - (1 - low / 100) * (1 - 0.9 * mid / 100) * (1 - 0.4 * high / 100))
    }

    private struct Raw: Decodable {
        let timezone: String?
        let utc_offset_seconds: Int?
        let elevation: Double?
        /// 键是 time 和 cloud_cover_low_ecmwf_ifs025 这种「变量_模型」
        let hourly: [String: [Double?]]
    }

    static func fetchClouds(latitude: Double, longitude: Double) async throws -> CloudForecast {
        guard let first = try await fetchClouds(at: [(latitude, longitude)]).first else { throw FetchError.emptyData }
        return first
    }

    /// 一次请求查多个坐标，结果顺序和输入一致
    static func fetchClouds(at coordinates: [(latitude: Double, longitude: Double)]) async throws -> [CloudForecast] {
        guard !coordinates.isEmpty else { return [] }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: coordinates.map { String(format: "%.3f", $0.latitude) }.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: coordinates.map { String(format: "%.3f", $0.longitude) }.joined(separator: ",")),
            URLQueryItem(name: "hourly", value: "cloud_cover,cloud_cover_low,cloud_cover_mid,cloud_cover_high"),
            URLQueryItem(name: "models", value: models.map(\.id).joined(separator: ",")),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "past_days", value: "1"),
            URLQueryItem(name: "forecast_days", value: "3"),
        ]
        let data = try await HTTP.get(components.url!)
        // 单个坐标返回对象，多个坐标返回数组
        let raws = coordinates.count == 1
            ? [try JSONDecoder().decode(Raw.self, from: data)]
            : try JSONDecoder().decode([Raw].self, from: data)
        return zip(coordinates, raws).map { coordinate, raw in
            forecast(from: raw, latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    /// 海拔（米），海面为 0。一次最多 100 个点，超过就分批
    static func fetchElevations(at coordinates: [(latitude: Double, longitude: Double)]) async throws -> [Double] {
        var result: [Double] = []
        for start in stride(from: 0, to: coordinates.count, by: 100) {
            let chunk = coordinates[start..<min(start + 100, coordinates.count)]
            var components = URLComponents(string: "https://api.open-meteo.com/v1/elevation")!
            components.queryItems = [
                URLQueryItem(name: "latitude", value: chunk.map { String(format: "%.4f", $0.latitude) }.joined(separator: ",")),
                URLQueryItem(name: "longitude", value: chunk.map { String(format: "%.4f", $0.longitude) }.joined(separator: ",")),
            ]
            struct Response: Decodable { let elevation: [Double] }
            let data = try await HTTP.get(components.url!)
            result += try JSONDecoder().decode(Response.self, from: data).elevation
        }
        return result
    }

    private static func forecast(from raw: Raw, latitude: Double, longitude: Double) -> CloudForecast {
        let h = raw.hourly
        func value(_ key: String, _ i: Int) -> Double? { (h[key]?[safe: i]) ?? nil }
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }

        var hours: [CloudForecast.Hour] = []
        for (i, time) in (h["time"] ?? []).enumerated() {
            guard let time else { continue }
            let clouds: [CloudForecast.ModelCloud] = models.compactMap { model in
                guard let total = value("cloud_cover_\(model.id)", i) else { return nil }
                let low = value("cloud_cover_low_\(model.id)", i)
                let mid = value("cloud_cover_mid_\(model.id)", i)
                let high = value("cloud_cover_high_\(model.id)", i)
                // 有的模型不分层，就只能用总云量
                let effective = if let low, let mid, let high {
                    effectiveCloud(low: low, mid: mid, high: high)
                } else {
                    total
                }
                return .init(id: model.id, label: model.label, total: total,
                             low: low ?? 0, mid: mid ?? 0, high: high ?? 0, effective: effective)
            }
            guard !clouds.isEmpty else { continue }
            hours.append(.init(
                time: Date(timeIntervalSince1970: time),
                total: mean(clouds.map(\.total)),
                low: mean(clouds.map(\.low)),
                mid: mean(clouds.map(\.mid)),
                high: mean(clouds.map(\.high)),
                effective: mean(clouds.map(\.effective)),
                models: clouds
            ))
        }
        let timeZone = raw.timezone.flatMap(TimeZone.init(identifier:))
            ?? raw.utc_offset_seconds.flatMap(TimeZone.init(secondsFromGMT:))
            ?? .current
        return CloudForecast(timeZone: timeZone, latitude: latitude, longitude: longitude,
                             elevation: raw.elevation, hours: hours)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
