import Foundation

/// 某一小时的综合观测条件
struct HourOutlook: Identifiable {
    let time: Date
    let kp: Double?
    /// 按 Kp 估算的「地平线上能看到」的可能性 0...1
    let auroraChance: Double
    /// 本地地平线可见需要的 Kp
    let kpHorizon: Double
    let sunAltitude: Double
    /// 天黑程度 0...1
    let darkness: Double
    /// 有效云量 %（几个模型平均、高云打折），没有数据时为 nil
    let cloud: Double?
    /// 分层和各模型的云量，评分拆解用
    let cloudDetail: CloudForecast.Hour?
    let moonAltitude: Double
    let moonIllumination: Double
    /// 月光系数 0...1
    let moon: Double
    /// 地点本身的光害系数（1 = 没有光害）
    let skyFactor: Double
    /// 按极光强度放宽后的光害系数，评分用这个
    let light: Double
    /// 综合评分 0...100
    let score: Double

    var id: Date { time }
}

enum Forecaster {
    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = Double.pi / 180
        let dLat = (lat2 - lat1) * r
        let dLon = (lon2 - lon1) * r
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * r) * cos(lat2 * r) * sin(dLon / 2) * sin(dLon / 2)
        return 6371 * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    /// OVATION 临近预报：头顶概率，以及视野内概率。
    /// 极光底部离地约 100 km，300 km 内都算「抬头可见」，约 1000 km 外沉到地平线下。
    static func nowcast(grid: OvationGrid, latitude: Double, longitude: Double) -> (overhead: Int, visible: Int) {
        let lat0 = Int(latitude.rounded())
        let lon0 = Int(longitude.rounded())
        let overhead = grid.value(lat: lat0, lon: lon0)

        var best = 0.0
        for dLat in -10...10 {
            let lat = lat0 + dLat
            guard (-90...90).contains(lat) else { continue }
            let cosLat = max(cos(Double(lat) * .pi / 180), 0.05)
            let span = min(Int((10 / cosLat).rounded(.up)), 180)
            for dLon in -span...span {
                let v = grid.value(lat: lat, lon: lon0 + dLon)
                guard Double(v) > best else { continue }
                let d = distanceKm(latitude, longitude, Double(lat), Double(lon0 + dLon))
                let weight = d <= 300 ? 1 : max(0, 1 - (d - 300) / 700)
                best = max(best, Double(v) * weight)
            }
        }
        return (overhead, Int(best.rounded()))
    }

    /// Kp 刚好达到本地地平线门槛时算 50%，每高 1 级 +25%
    static func auroraChance(kp: Double, kpHorizon: Double) -> Double {
        min(max(0.5 + (kp - kpHorizon) * 0.25, 0), 1)
    }

    /// 太阳高度 −6°（民用晨昏）以上算 0，−15° 以下算完全黑
    static func darkness(sunAltitude: Double) -> Double {
        min(max((-6 - sunAltitude) / 9, 0), 1)
    }

    /// 光害系数随极光强度放宽：Kp 刚到本地门槛时按原值扣，超过 3 级以上扣分减半（亮的极光不怕城里的灯）
    static func lightFactor(skyFactor: Double, kp: Double?, kpHorizon: Double) -> Double {
        guard let kp else { return skyFactor }
        let strength = min(max((kp - kpHorizon) / 3, 0), 1)
        return 1 - (1 - skyFactor) * (1 - 0.5 * strength)
    }

    /// 满月高挂时最多扣 40%
    static func moonFactor(altitude: Double, illumination: Double) -> Double {
        guard altitude > 0 else { return 1 }
        return 1 - 0.4 * illumination * min(altitude / 30, 1)
    }

    static func kp(at date: Date, in points: [KpPoint]) -> KpPoint? {
        points.last { $0.time <= date && date < $0.end }
    }

    /// 从现在开始的第一段黑夜（最多 24 小时），逐小时给出评分
    static func outlook(latitude: Double, longitude: Double, kp points: [KpPoint],
                        clouds: CloudForecast?, skyFactor: Double = 1, now: Date = .now) -> [HourOutlook] {
        let kpHorizon = Geomag.kpNeeded(latitude: latitude, longitude: longitude).horizon
        let startHour = (now.timeIntervalSince1970 / 3600).rounded(.down) * 3600
        var result: [HourOutlook] = []

        for i in 0..<40 {
            let time = Date(timeIntervalSince1970: startHour + Double(i) * 3600)
            let mid = time + 1800
            let sunAlt = Astro.sunAltitude(at: mid, latitude: latitude, longitude: longitude)
            let dark = darkness(sunAltitude: sunAlt)
            if dark <= 0 {
                if result.isEmpty { continue } else { break }
            }
            if result.count >= 24 { break }

            let kp = kp(at: mid, in: points)?.kp
            let moonAlt = Astro.moonAltitude(at: mid, latitude: latitude, longitude: longitude)
            let illumination = Astro.moonIllumination(at: mid)
            let cloudDetail = clouds?.hour(near: mid)
            let cloud = cloudDetail?.effective
            let aurora = kp.map { auroraChance(kp: $0, kpHorizon: kpHorizon) } ?? 0
            let moon = moonFactor(altitude: moonAlt, illumination: illumination)
            let light = lightFactor(skyFactor: skyFactor, kp: kp, kpHorizon: kpHorizon)
            let score = 100 * aurora * dark * (1 - (cloud ?? 0) / 100) * moon * light

            result.append(HourOutlook(time: time, kp: kp, auroraChance: aurora, kpHorizon: kpHorizon,
                                      sunAltitude: sunAlt, darkness: dark, cloud: cloud, cloudDetail: cloudDetail,
                                      moonAltitude: moonAlt, moonIllumination: illumination, moon: moon,
                                      skyFactor: skyFactor, light: light, score: score))
        }
        return result
    }
}
