import Foundation

/// 一个候选观测点今晚的情况
struct SpotForecast: Identifiable {
    var place: Place
    /// 离当前地点的距离（km）和方位（度，正北为 0）。热门目的地没有
    let distanceKm: Double?
    let bearing: Double?
    let timeZone: TimeZone
    let hours: [HourOutlook]
    /// OVATION 现在的视野内概率
    let nowVisible: Int?
    let clouds: CloudForecast?
    /// 光污染等级
    var sky: LightZone?
    /// 原坐标在村镇里、被挪到附近更暗的地方时，原来的等级和挪动距离
    var originalSky: LightZone?
    var shiftKm: Double?
    /// 具体观测点：类型和极光方向的地平线
    var kind: SpotKind?
    var horizon: HorizonView?
    /// 光害系数（1 = 没有光害）
    var siteFactor: Double = 1

    var id: String { place.id }
    var best: HourOutlook? { hours.max { $0.score < $1.score } }
    var bestScore: Double { best?.score ?? 0 }

    /// 「北 80 km」这种相对说法
    var directionText: String? {
        guard let distanceKm, let bearing else { return nil }
        if distanceKm < 5 { return "原地" }
        return "\(Spots.compass(bearing)) \(Int(distanceKm.rounded())) km"
    }
}

enum Spots {
    /// 热门极光目的地（也作为设置里的预设地点）
    static let destinations: [Place] = [
        Place(id: "tromso", name: "特罗姆瑟", latitude: 69.65, longitude: 18.96),
        Place(id: "lofoten", name: "罗弗敦群岛", latitude: 68.23, longitude: 14.56),
        Place(id: "abisko", name: "阿比斯库", latitude: 68.35, longitude: 18.83),
        Place(id: "kiruna", name: "基律纳", latitude: 67.86, longitude: 20.23),
        Place(id: "rovaniemi", name: "罗瓦涅米", latitude: 66.50, longitude: 25.73),
        Place(id: "saariselka", name: "萨里塞尔卡", latitude: 68.42, longitude: 27.41),
        Place(id: "murmansk", name: "摩尔曼斯克", latitude: 68.97, longitude: 33.08),
        Place(id: "reykjavik", name: "雷克雅未克", latitude: 64.15, longitude: -21.94),
        Place(id: "akureyri", name: "阿克雷里", latitude: 65.68, longitude: -18.09),
        Place(id: "fairbanks", name: "费尔班克斯", latitude: 64.84, longitude: -147.72),
        Place(id: "whitehorse", name: "白马镇", latitude: 60.72, longitude: -135.06),
        Place(id: "yellowknife", name: "黄刀镇", latitude: 62.45, longitude: -114.37),
        Place(id: "churchill", name: "丘吉尔", latitude: 58.77, longitude: -94.17),
        Place(id: "mohe", name: "漠河", latitude: 52.97, longitude: 122.54),
        Place(id: "tekapo", name: "特卡波", latitude: -44.00, longitude: 170.48),
        Place(id: "queenstown", name: "皇后镇", latitude: -45.03, longitude: 168.66),
        Place(id: "hobart", name: "霍巴特", latitude: -42.88, longitude: 147.33),
    ]

    /// 当前地点周围的候选点：原地 + 8 个方向 × 3 个距离
    static func nearbyCandidates(around center: Place) -> [(place: Place, distance: Double, bearing: Double)] {
        var result = [(center, 0.0, 0.0)]
        for distance in [50.0, 100.0, 150.0] {
            for bearing in stride(from: 0.0, to: 360.0, by: 45.0) {
                let (lat, lon) = destination(from: center.latitude, center.longitude, distanceKm: distance, bearing: bearing)
                let place = Place(id: "nearby-\(Int(bearing))-\(Int(distance))",
                                  name: "\(compass(bearing)) \(Int(distance)) km",
                                  latitude: lat, longitude: lon)
                result.append((place, distance, bearing))
            }
        }
        return result
    }

    static func forecast(for place: Place, clouds: CloudForecast?, kp: [KpPoint], ovation: OvationGrid?,
                         sky: LightZone?, skyFactor: Double? = nil, distanceKm: Double? = nil, bearing: Double? = nil,
                         now: Date = .now) -> SpotForecast {
        let factor = skyFactor ?? sky?.skyFactor ?? 1
        var spot = SpotForecast(
            place: place,
            distanceKm: distanceKm,
            bearing: bearing,
            timeZone: clouds?.timeZone ?? .current,
            hours: Forecaster.outlook(latitude: place.latitude, longitude: place.longitude, kp: kp,
                                      clouds: clouds, skyFactor: factor, now: now),
            nowVisible: ovation.map { Forecaster.nowcast(grid: $0, latitude: place.latitude, longitude: place.longitude).visible },
            clouds: clouds,
            sky: sky
        )
        spot.siteFactor = factor
        return spot
    }

    /// 把观测点挪到附近更暗的地方（云量沿用原来的，几 km 内差别不大）
    static func relocate(_ spot: SpotForecast, to dark: DarkSpot, kp: [KpPoint], ovation: OvationGrid?) -> SpotForecast {
        var place = spot.place
        place.latitude = dark.latitude
        place.longitude = dark.longitude
        var moved = forecast(for: place, clouds: spot.clouds, kp: kp, ovation: ovation, sky: dark.zone,
                             distanceKm: spot.distanceKm, bearing: spot.bearing)
        moved.originalSky = spot.sky
        moved.shiftKm = dark.distanceKm
        return moved
    }

    /// 具体观测点
    static func forecast(for candidate: ViewingCandidate, clouds: CloudForecast?, kp: [KpPoint], ovation: OvationGrid?) -> SpotForecast {
        let place = Place(id: String(format: "spot-%.4f,%.4f", candidate.latitude, candidate.longitude),
                          name: candidate.name, latitude: candidate.latitude, longitude: candidate.longitude)
        var spot = forecast(for: place, clouds: clouds, kp: kp, ovation: ovation, sky: candidate.ground,
                            skyFactor: candidate.skyFactor, distanceKm: candidate.distanceKm, bearing: candidate.bearing)
        spot.kind = candidate.kind
        spot.horizon = candidate.horizon
        return spot
    }

    /// 观测点排序：今晚评分（评分都是 0 时看光害系数），走到半径边上打 85 折，
    /// 没名字的暗处和城里的公园再打一点折扣（差不多时优先有名字的公共地方）；挑出彼此不太挨着的几个
    static func pickViewing(_ spots: [SpotForecast], count: Int, radiusKm: Double) -> [SpotForecast] {
        func value(_ spot: SpotForecast) -> Double {
            (spot.bestScore + spot.siteFactor * 10) * (1 - 0.15 * min((spot.distanceKm ?? 0) / radiusKm, 1))
                * (1 - 0.03 * Double(spot.kind?.preference ?? 0))
        }
        let sorted = spots.sorted { value($0) > value($1) }
        var picked: [SpotForecast] = []
        // 离原地 300 m 以内的就是「原地」，不单独列
        for spot in sorted where picked.count < count && (spot.distanceKm ?? 0) >= 0.3 {
            let farEnough = picked.allSatisfy {
                Forecaster.distanceKm($0.place.latitude, $0.place.longitude, spot.place.latitude, spot.place.longitude) >= radiusKm / 6
            }
            if farEnough { picked.append(spot) }
        }
        return picked
    }

    /// 按 5 分一档排序，同一档里近的在前
    static func rankNearby(_ spots: [SpotForecast]) -> [SpotForecast] {
        spots.sorted { a, b in
            let tierA = Int(a.bestScore / 5), tierB = Int(b.bestScore / 5)
            if tierA != tierB { return tierA > tierB }
            return (a.distanceKm ?? 0) < (b.distanceKm ?? 0)
        }
    }

    /// 「北偏西 17°」这种精确方向
    static func preciseDirection(_ bearing: Double) -> String {
        let b = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let fromNorth = b > 180 ? 360 - b : b
        let base = fromNorth <= 90 ? "北" : "南"
        let offset = Int((fromNorth <= 90 ? fromNorth : 180 - fromNorth).rounded())
        if offset <= 2 { return "正\(base)" }
        if offset >= 88 { return b < 180 ? "正东" : "正西" }
        return "\(base)偏\(b < 180 ? "东" : "西") \(offset)°"
    }

    static func compass(_ bearing: Double) -> String {
        let names = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        return names[Int(((bearing.truncatingRemainder(dividingBy: 360) + 360 + 22.5) / 45).rounded(.down)) % 8]
    }

    static func destination(from lat: Double, _ lon: Double, distanceKm: Double, bearing: Double) -> (Double, Double) {
        let r = Double.pi / 180
        let delta = distanceKm / 6371
        let phi1 = lat * r, lambda1 = lon * r, theta = bearing * r
        let phi2 = asin(sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta))
        let lambda2 = lambda1 + atan2(sin(theta) * sin(delta) * cos(phi1), cos(delta) - sin(phi1) * sin(phi2))
        var lon2 = lambda2 / r
        lon2 = (lon2 + 540).truncatingRemainder(dividingBy: 360) - 180
        return (phi2 / r, lon2)
    }
}
