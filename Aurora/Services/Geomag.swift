import Foundation

/// 地磁纬度（偏心偶极子近似）和「需要多大的 Kp 才能看到」的估算
enum Geomag {
    // IGRF 约 2025 年的前 8 个高斯系数（nT）
    private static let g10 = -29350.0, g11 = -1410.3, h11 = 4545.5
    private static let g20 = -2556.2, g21 = 2950.9, h21 = -3133.6
    private static let g22 = 1648.7, h22 = -814.2

    /// 偶极子北极方向（单位向量）和偶极子中心相对地心的偏移（地球半径为单位）
    private static let dipole: (pole: SIMD3<Double>, offset: SIMD3<Double>) = {
        let b0Squared = g10 * g10 + g11 * g11 + h11 * h11
        let b0 = b0Squared.squareRoot()
        let s3 = 3.0.squareRoot()
        let l0 = 2 * g10 * g20 + s3 * (g11 * g21 + h11 * h21)
        let l1 = -g11 * g20 + s3 * (g10 * g21 + g11 * g22 + h11 * h22)
        let l2 = -h11 * g20 + s3 * (g10 * h21 - h11 * g22 + g11 * h22)
        let e = (l0 * g10 + l1 * g11 + l2 * h11) / (4 * b0Squared)
        let xi = (l0 - g10 * e) / (3 * b0Squared)
        let eta = (l1 - g11 * e) / (3 * b0Squared)
        let zeta = (l2 - h11 * e) / (3 * b0Squared)
        let pole = SIMD3(-g11, -h11, -g10) / b0
        return (pole, SIMD3(eta, zeta, xi))
    }()

    /// 地磁纬度（度），南半球为负
    static func magneticLatitude(latitude: Double, longitude: Double) -> Double {
        let phi = latitude * .pi / 180
        let lambda = longitude * .pi / 180
        let position = SIMD3(cos(phi) * cos(lambda), cos(phi) * sin(lambda), sin(phi)) - dipole.offset
        let length = (position * position).sum().squareRoot()
        let sinLat = (position * dipole.pole).sum() / length
        return asin(min(max(sinLat, -1), 1)) * 180 / .pi
    }

    /// 极光出现的方向：朝向本半球地磁极的方位角（度，正北为 0）
    static func auroraBearing(latitude: Double, longitude: Double) -> Double {
        let pole = dipole.pole
        var poleLat = asin(pole.z) * 180 / .pi
        var poleLon = atan2(pole.y, pole.x) * 180 / .pi
        if latitude < 0 {
            poleLat = -poleLat
            poleLon += 180
        }
        let r = Double.pi / 180
        let phi1 = latitude * r, phi2 = poleLat * r
        let dLon = (poleLon - longitude) * r
        let y = sin(dLon) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLon)
        return (atan2(y, x) / r + 360).truncatingRemainder(dividingBy: 360)
    }

    /// 极光卵南缘大约在磁纬 66.5° − 2.05×Kp；在地平线上能看到的范围再往低纬约 4.5°。
    static func kpNeeded(magneticLatitude: Double) -> (overhead: Double, horizon: Double) {
        let m = abs(magneticLatitude)
        return ((66.5 - m) / 2.05, (62.0 - m) / 2.05)
    }

    static func kpNeeded(latitude: Double, longitude: Double) -> (overhead: Double, horizon: Double) {
        kpNeeded(magneticLatitude: magneticLatitude(latitude: latitude, longitude: longitude))
    }
}
