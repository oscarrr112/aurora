import Foundation

/// Open-Meteo 云量预报（免费、无需 Key）
enum WeatherClient {
    private struct Raw: Decodable {
        struct Hourly: Decodable {
            let time: [Double]
            let cloud_cover: [Double?]
            let cloud_cover_low: [Double?]
            let cloud_cover_mid: [Double?]
            let cloud_cover_high: [Double?]
        }

        let timezone: String?
        let utc_offset_seconds: Int?
        let elevation: Double?
        let hourly: Hourly
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
        var hours: [CloudForecast.Hour] = []
        for i in h.time.indices {
            guard let total = h.cloud_cover[safe: i] ?? nil else { continue }
            hours.append(.init(
                time: Date(timeIntervalSince1970: h.time[i]),
                total: total,
                low: (h.cloud_cover_low[safe: i] ?? nil) ?? 0,
                mid: (h.cloud_cover_mid[safe: i] ?? nil) ?? 0,
                high: (h.cloud_cover_high[safe: i] ?? nil) ?? 0
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
