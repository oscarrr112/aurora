import Foundation

/// 太阳、月亮位置的低精度算法（移植自 SunCalc，误差约 1°，用来判断天黑和月光足够了）
enum Astro {
    private static let rad = Double.pi / 180
    private static let obliquity = rad * 23.4397

    private static func days(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400 - 0.5 + 2440588 - 2451545
    }

    private static func rightAscension(_ l: Double, _ b: Double) -> Double {
        atan2(sin(l) * cos(obliquity) - tan(b) * sin(obliquity), cos(l))
    }

    private static func declination(_ l: Double, _ b: Double) -> Double {
        asin(sin(b) * cos(obliquity) + cos(b) * sin(obliquity) * sin(l))
    }

    private static func altitude(_ h: Double, _ phi: Double, _ dec: Double) -> Double {
        asin(sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(h))
    }

    private static func siderealTime(_ d: Double, _ lw: Double) -> Double {
        rad * (280.16 + 360.9856235 * d) - lw
    }

    private static func sunCoords(_ d: Double) -> (dec: Double, ra: Double) {
        let m = rad * (357.5291 + 0.98560028 * d)
        let c = rad * (1.9148 * sin(m) + 0.02 * sin(2 * m) + 0.0003 * sin(3 * m))
        let l = m + c + rad * 102.9372 + Double.pi
        return (declination(l, 0), rightAscension(l, 0))
    }

    private static func moonCoords(_ d: Double) -> (dec: Double, ra: Double, dist: Double) {
        let l0 = rad * (218.316 + 13.176396 * d)
        let m = rad * (134.963 + 13.064993 * d)
        let f = rad * (93.272 + 13.229350 * d)
        let l = l0 + rad * 6.289 * sin(m)
        let b = rad * 5.128 * sin(f)
        return (declination(l, b), rightAscension(l, b), 385001 - 20905 * cos(m))
    }

    /// 太阳高度角（度）
    static func sunAltitude(at date: Date, latitude: Double, longitude: Double) -> Double {
        let d = days(date)
        let c = sunCoords(d)
        let h = siderealTime(d, rad * -longitude) - c.ra
        return altitude(h, rad * latitude, c.dec) / rad
    }

    /// 月亮高度角（度）
    static func moonAltitude(at date: Date, latitude: Double, longitude: Double) -> Double {
        let d = days(date)
        let c = moonCoords(d)
        let h = siderealTime(d, rad * -longitude) - c.ra
        return altitude(h, rad * latitude, c.dec) / rad
    }

    /// 太阳直射点（度）
    static func subsolarPoint(at date: Date) -> (latitude: Double, longitude: Double) {
        let d = days(date)
        let c = sunCoords(d)
        var lon = (c.ra - siderealTime(d, 0)) / rad
        lon = (lon.truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360) - 180
        return (c.dec / rad, lon)
    }

    /// 月面被照亮的比例 0...1
    static func moonIllumination(at date: Date) -> Double {
        let d = days(date)
        let s = sunCoords(d)
        let m = moonCoords(d)
        let sunDistance = 149598000.0
        let phi = acos(sin(s.dec) * sin(m.dec) + cos(s.dec) * cos(m.dec) * cos(s.ra - m.ra))
        let inc = atan2(sunDistance * sin(phi), m.dist - sunDistance * cos(phi))
        return (1 + cos(inc)) / 2
    }

    /// 包含 `date`、或在它之后最近的一段黑夜（太阳低于 `threshold` 度）。24 小时内都不会天黑时返回 nil。
    static func darkWindow(around date: Date, latitude: Double, longitude: Double,
                           threshold: Double = -12) -> DateInterval? {
        let step: TimeInterval = 5 * 60
        func isDark(_ t: Date) -> Bool {
            sunAltitude(at: t, latitude: latitude, longitude: longitude) < threshold
        }

        var start: Date
        if isDark(date) {
            start = date
            for _ in 0..<(24 * 12) {
                let previous = start - step
                if !isDark(previous) { break }
                start = previous
            }
        } else {
            guard let s = stride(from: date, through: date + 24 * 3600, by: step).first(where: isDark) else {
                return nil
            }
            start = s
        }

        var end = start
        for _ in 0..<(36 * 12) {
            end += step
            if !isDark(end) { break }
        }
        return DateInterval(start: start, end: end)
    }
}
