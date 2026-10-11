import Foundation

/// NOAA OVATION 极光模型：全球 1°×1° 网格上「头顶出现极光」的概率（0–100）
struct OvationGrid {
    let observationTime: Date
    let forecastTime: Date
    /// 索引 = (lat + 90) * 360 + lon，lon 取 0...359，lat 取 -90...90
    let values: [UInt8]

    func value(lat: Int, lon: Int) -> Int {
        guard (-90...90).contains(lat) else { return 0 }
        let l = ((lon % 360) + 360) % 360
        return Int(values[(lat + 90) * 360 + l])
    }
}

struct KpPoint: Identifiable {
    enum Kind: String {
        case observed, estimated, predicted
    }

    /// 3 小时区间的起点（UTC）
    let time: Date
    let kp: Double
    let kind: Kind
    /// G1...G5 磁暴等级
    let scale: String?

    var id: Date { time }
    var end: Date { time + 3 * 3600 }
}

struct SolarWindSample: Identifiable {
    let time: Date
    var bz: Double?
    var bt: Double?
    var speed: Double?
    var density: Double?

    var id: Date { time }
}

struct CloudForecast {
    struct Hour {
        let time: Date
        let total: Double
        let low: Double
        let mid: Double
        let high: Double
    }

    let timeZone: TimeZone
    let latitude: Double
    let longitude: Double
    /// 海拔（米）。海面上返回 0
    let elevation: Double?
    let hours: [Hour]

    func hour(near date: Date) -> Hour? {
        guard let best = hours.min(by: { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }),
              abs(best.time.timeIntervalSince(date)) <= 2 * 3600 else { return nil }
        return best
    }
}
