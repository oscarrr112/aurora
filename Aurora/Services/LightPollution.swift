import CoreGraphics
import Foundation
import ImageIO

/// 光污染等级（David Lorenz《Light Pollution Atlas》的分区，天顶天空亮度）
struct LightZone: Hashable {
    let index: Int
    let name: String
    /// 该区天空亮度的中值（mag/arcsec²，越大越黑，22.0 为无人造光）
    let sqm: Double
    let rgb: (Int, Int, Int)

    static func == (a: LightZone, b: LightZone) -> Bool { a.index == b.index }
    func hash(into hasher: inout Hasher) { hasher.combine(index) }

    var summary: String {
        switch index {
        case 0...2: "几乎没有光害"
        case 3...4: "很暗"
        case 5...6: "乡村，暗"
        case 7...8: "郊区，地平线有光"
        case 9...10: "城郊，光害明显"
        case 11...12: "城市"
        default: "市中心"
        }
    }

    /// 光害对看极光的影响：弱极光会被淹没，强极光影响小，这里取一个折中系数
    var skyFactor: Double {
        [1, 1, 1, 0.99, 0.98, 0.96, 0.93, 0.88, 0.82, 0.74, 0.65, 0.55, 0.46, 0.38, 0.30][index]
    }

    static let all: [LightZone] = [
        LightZone(index: 0, name: "0", sqm: 22.0, rgb: (0, 0, 0)),
        LightZone(index: 1, name: "1a", sqm: 21.96, rgb: (34, 34, 34)),
        LightZone(index: 2, name: "1b", sqm: 21.91, rgb: (66, 66, 66)),
        LightZone(index: 3, name: "2a", sqm: 21.85, rgb: (20, 47, 114)),
        LightZone(index: 4, name: "2b", sqm: 21.75, rgb: (33, 84, 216)),
        LightZone(index: 5, name: "3a", sqm: 21.60, rgb: (15, 87, 20)),
        LightZone(index: 6, name: "3b", sqm: 21.38, rgb: (31, 161, 42)),
        LightZone(index: 7, name: "4a", sqm: 21.08, rgb: (110, 100, 30)),
        LightZone(index: 8, name: "4b", sqm: 20.70, rgb: (184, 166, 37)),
        LightZone(index: 9, name: "5a", sqm: 20.25, rgb: (191, 100, 30)),
        LightZone(index: 10, name: "5b", sqm: 19.76, rgb: (253, 150, 80)),
        LightZone(index: 11, name: "6a", sqm: 19.22, rgb: (251, 90, 73)),
        LightZone(index: 12, name: "6b", sqm: 18.66, rgb: (251, 153, 138)),
        LightZone(index: 13, name: "7a", sqm: 18.09, rgb: (160, 160, 160)),
        LightZone(index: 14, name: "7b", sqm: 17.60, rgb: (242, 242, 242)),
    ]
}

/// 某个点附近、在陆地上的最暗位置
struct DarkSpot {
    let latitude: Double
    let longitude: Double
    let zone: LightZone
    let distanceKm: Double
    let bearing: Double
}

/// 读取 Lorenz 光污染地图集的瓦片（z=6，1024 像素，北纬 70° 约 0.2 km 一个像素）。
/// 数据是年度的，瓦片缓存在磁盘上。
actor LightPollutionStore {
    static let shared = LightPollutionStore()

    private static let year = 2025
    private static let zoom = 6
    private static let tileSize = 1024
    private static let unknown: UInt8 = 255

    private struct TileKey: Hashable {
        let x: Int
        let y: Int
    }

    private var tiles: [TileKey: [UInt8]] = [:]
    private var tileOrder: [TileKey] = []
    private var inFlight: [TileKey: Task<[UInt8]?, Never>] = [:]

    private static let colorIndex: [Int: UInt8] = {
        var map: [Int: UInt8] = [:]
        for zone in LightZone.all {
            map[zone.rgb.0 << 16 | zone.rgb.1 << 8 | zone.rgb.2] = UInt8(zone.index)
        }
        return map
    }()

    private static var cacheDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "lightpollution\(year)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: 查询

    func zone(latitude: Double, longitude: Double) async -> LightZone? {
        let (key, px, py) = Self.locate(latitude: latitude, longitude: longitude)
        guard let tile = await tile(key) else { return nil }
        let value = tile[py * Self.tileSize + px]
        return value == Self.unknown ? nil : LightZone.all[Int(value)]
    }

    func zones(for coordinates: [(latitude: Double, longitude: Double)]) async -> [LightZone?] {
        var result: [LightZone?] = []
        for c in coordinates {
            result.append(await zone(latitude: c.latitude, longitude: c.longitude))
        }
        return result
    }

    /// 半径内最暗的若干个点（按光害从低到高、距离从近到远），彼此至少相隔 minSpacingKm。
    /// 海面在图上也是全黑，调用方需要再用海拔排除海面。
    func darkCandidates(latitude: Double, longitude: Double, radiusKm: Double, count: Int,
                        minSpacingKm: Double = 1) async -> [DarkSpot] {
        let step = max(radiusKm / 12, 0.4)
        let steps = Int((radiusKm / step).rounded(.up))
        var samples: [DarkSpot] = []

        for iy in -steps...steps {
            for ix in -steps...steps {
                let dx = Double(ix) * step, dy = Double(iy) * step
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance <= radiusKm else { continue }
                let lat = latitude + dy / 111.2
                let lon = longitude + dx / (111.2 * max(cos(latitude * .pi / 180), 0.05))
                guard let zone = await zone(latitude: lat, longitude: lon) else { continue }
                let bearing = (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
                samples.append(DarkSpot(latitude: lat, longitude: lon, zone: zone, distanceKm: distance, bearing: bearing))
            }
        }

        samples.sort { ($0.zone.index, $0.distanceKm) < ($1.zone.index, $1.distanceKm) }
        var picked: [DarkSpot] = []
        for sample in samples {
            let farEnough = picked.allSatisfy {
                Forecaster.distanceKm($0.latitude, $0.longitude, sample.latitude, sample.longitude) >= minSpacingKm
            }
            if farEnough { picked.append(sample) }
            if picked.count >= count { break }
        }
        return picked
    }

    /// 地图图层用：z=6 瓦片 (x, y) 里从 (srcX, srcY) 开始、边长 size 像素的方块，
    /// 按最近邻缩放到 outSize × outSize，返回每个像素的区号（255 = 未知）
    func zoneBlock(tileX: Int, tileY: Int, srcX: Int, srcY: Int, size: Int, outSize: Int) async -> [UInt8]? {
        let n = 1 << Self.zoom
        guard (0..<n).contains(tileX), (0..<n).contains(tileY),
              let tile = await tile(TileKey(x: tileX, y: tileY)) else { return nil }
        var out = [UInt8](repeating: Self.unknown, count: outSize * outSize)
        for oy in 0..<outSize {
            let sy = min(max(srcY + oy * size / outSize, 0), Self.tileSize - 1)
            for ox in 0..<outSize {
                let sx = min(max(srcX + ox * size / outSize, 0), Self.tileSize - 1)
                out[oy * outSize + ox] = tile[sy * Self.tileSize + sx]
            }
        }
        return out
    }

    static let atlasZoom = zoom
    static let atlasTileSize = tileSize

    // MARK: 瓦片

    private static func locate(latitude: Double, longitude: Double) -> (TileKey, Int, Int) {
        let n = Double(1 << zoom)
        let lat = min(max(latitude, -85), 85)
        let x = (longitude + 180) / 360 * n
        let y = (1 - asinh(tan(lat * .pi / 180)) / .pi) / 2 * n
        let tx = min(max(Int(x), 0), Int(n) - 1)
        let ty = min(max(Int(y), 0), Int(n) - 1)
        let px = min(max(Int((x - Double(tx)) * Double(tileSize)), 0), tileSize - 1)
        let py = min(max(Int((y - Double(ty)) * Double(tileSize)), 0), tileSize - 1)
        return (TileKey(x: tx, y: ty), px, py)
    }

    private func tile(_ key: TileKey) async -> [UInt8]? {
        if let cached = tiles[key] { return cached }
        if let task = inFlight[key] { return await task.value }

        let task = Task.detached(priority: .utility) { await Self.loadTile(key) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        if let result {
            tiles[key] = result
            tileOrder.append(key)
            // 每张解码后 1 MB，最多留 30 张在内存里
            if tileOrder.count > 30 { tiles[tileOrder.removeFirst()] = nil }
        }
        return result
    }

    private static func loadTile(_ key: TileKey) async -> [UInt8]? {
        let file = cacheDirectory.appending(path: "tile_\(zoom)_\(key.x)_\(key.y).png")
        var data = try? Data(contentsOf: file)
        if data == nil {
            let url = URL(string: "https://djlorenz.github.io/astronomy/image_tiles/tiles\(year)/tile_\(zoom)_\(key.x)_\(key.y).png")!
            guard let (downloaded, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse else { return nil }
            // 没有瓦片的地方（大洋、极区）就是没有灯光
            if http.statusCode == 404 { return [UInt8](repeating: 0, count: tileSize * tileSize) }
            guard http.statusCode == 200 else { return nil }
            try? downloaded.write(to: file)
            data = downloaded
        }
        guard let data else { return nil }
        return decode(data)
    }

    /// PNG → 每个像素的区号
    private static func decode(_ data: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == tileSize, image.height == tileSize else { return nil }

        var rgba = [UInt8](repeating: 0, count: tileSize * tileSize * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: tileSize, height: tileSize,
                                          bitsPerComponent: 8, bytesPerRow: tileSize * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: tileSize, height: tileSize))
            return true
        }
        guard drawn else { return nil }

        var zones = [UInt8](repeating: unknown, count: tileSize * tileSize)
        for i in 0..<(tileSize * tileSize) {
            let p = i * 4
            let key = Int(rgba[p]) << 16 | Int(rgba[p + 1]) << 8 | Int(rgba[p + 2])
            zones[i] = colorIndex[key] ?? unknown
        }
        return zones
    }
}
