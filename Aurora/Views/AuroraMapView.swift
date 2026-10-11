import MapKit
import SwiftUI

struct AuroraMapScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                AuroraMapView(grid: model.ovation, place: model.activePlace, spots: model.destinations) { id in
                    model.select(id)
                    model.tab = .tonight
                }
                .ignoresSafeArea(edges: .top)
                legend
                    .padding()
            }
            .navigationTitle("极光概率图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { RefreshButton() }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            LinearGradient(stops: OvationOverlay.legendStops, startPoint: .leading, endPoint: .trailing)
                .frame(height: 8)
                .clipShape(Capsule())
            HStack {
                Text("5%")
                Spacer()
                Text("头顶出现极光的概率")
                Spacer()
                Text("80%+")
            }
            .font(.caption2)
            if let grid = model.ovation {
                let maxValue = Int(grid.values.max() ?? 0)
                Text(maxValue < 20 ? "现在全球极光偏弱（最高 \(maxValue)%）" : "现在全球最高 \(maxValue)%")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(maxValue < 20 ? .secondary : Palette.aurora)
            }
            Text("亮的一侧是白天，暗的一侧才看得到极光。圆点是热门目的地今晚的评分，点开可切换。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let grid = model.ovation {
                Text("NOAA OVATION 模型 · 预测时刻 \(Fmt.time(grid.forecastTime, .current))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct AuroraMapView: UIViewRepresentable {
    let grid: OvationGrid?
    let place: Place?
    let spots: [SpotForecast]
    let onSelectPlace: (String) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
        map.pointOfInterestFilter = .excludingAll
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.spotID)
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.placeID)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelectPlace = onSelectPlace

        if let grid, grid.forecastTime != coordinator.shownForecastTime {
            coordinator.shownForecastTime = grid.forecastTime
            // 生成图像要几百毫秒，放到后台
            Task.detached(priority: .userInitiated) {
                let overlay = OvationOverlay(grid: grid)
                await MainActor.run {
                    guard coordinator.shownForecastTime == grid.forecastTime else { return }
                    map.removeOverlays(map.overlays)
                    map.addOverlay(overlay, level: .aboveRoads)
                }
            }
        }

        if place?.id != coordinator.shownPlace?.id || place?.latitude != coordinator.shownPlace?.latitude {
            map.removeAnnotations(map.annotations.filter { $0 is PlaceAnnotation })
            if let place {
                map.addAnnotation(PlaceAnnotation(place: place))
                // 往极区方向偏一点，让极光卵进入画面
                let centerLat = min(max(place.latitude + (place.latitude >= 0 ? 6 : -6), -75), 75)
                map.setRegion(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: centerLat, longitude: place.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 35, longitudeDelta: 70)
                ), animated: coordinator.shownPlace != nil)
            }
            coordinator.shownPlace = place
        }

        let signature = spots.map { "\($0.id):\(Int($0.bestScore))" }.joined(separator: ",") + (place?.id ?? "")
        if signature != coordinator.shownSpots {
            coordinator.shownSpots = signature
            map.removeAnnotations(map.annotations.filter { $0 is SpotAnnotation })
            map.addAnnotations(spots.filter { $0.id != place?.id }.map(SpotAnnotation.init(spot:)))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        static let spotID = "spot"
        static let placeID = "place"

        var shownForecastTime: Date?
        var shownPlace: Place?
        var shownSpots = ""
        var onSelectPlace: ((String) -> Void)?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let overlay = overlay as? OvationOverlay {
                return OvationRenderer(overlay: overlay)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let spot = annotation as? SpotAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.spotID, for: spot) as! MKMarkerAnnotationView
                view.markerTintColor = UIColor(Palette.score(spot.score))
                view.glyphText = "\(Int(spot.score))"
                view.titleVisibility = .adaptive
                view.subtitleVisibility = .hidden
                view.displayPriority = .defaultHigh
                view.canShowCallout = true
                let button = UIButton(type: .system)
                button.setImage(UIImage(systemName: "arrow.right.circle.fill"), for: .normal)
                button.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
                view.rightCalloutAccessoryView = button
                return view
            }
            if let place = annotation as? PlaceAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.placeID, for: place) as! MKMarkerAnnotationView
                view.markerTintColor = .systemBlue
                view.glyphImage = UIImage(systemName: "person.fill")
                view.displayPriority = .required
                view.canShowCallout = true
                view.rightCalloutAccessoryView = nil
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            if let spot = view.annotation as? SpotAnnotation {
                onSelectPlace?(spot.placeID)
            }
        }
    }
}

final class PlaceAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(place: Place) {
        coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        title = place.name
    }
}

final class SpotAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let score: Double
    let placeID: String

    init(spot: SpotForecast) {
        coordinate = CLLocationCoordinate2D(latitude: spot.place.latitude, longitude: spot.place.longitude)
        title = spot.place.name
        score = spot.bestScore
        placeID = spot.id
        if let best = spot.best, best.score >= 1 {
            subtitle = "今晚最高 \(Int(best.score)) 分 · \(Fmt.time(best.time, spot.timeZone))"
        } else {
            subtitle = "今晚希望不大"
        }
    }
}

/// 把 OVATION 1° 网格平滑插值后，按墨卡托投影画成一张整图
final class OvationOverlay: NSObject, MKOverlay {
    let image: CGImage?
    let boundingMapRect: MKMapRect
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)

    private static let maxLatitude = 84.0

    /// 概率 → 颜色和不透明度。低概率几乎透明，避免整片极区糊成一块
    private static let stops: [(value: Float, rgb: (Float, Float, Float), alpha: Float)] = [
        (2, (0.10, 0.80, 0.45), 0.0),
        (5, (0.15, 0.95, 0.50), 0.28),
        (12, (0.25, 1.00, 0.55), 0.50),
        (25, (0.40, 1.00, 0.50), 0.65),
        (45, (0.90, 0.95, 0.30), 0.75),
        (65, (1.00, 0.55, 0.20), 0.82),
        (85, (1.00, 0.25, 0.55), 0.88),
    ]

    static var legendStops: [Gradient.Stop] {
        stops.dropFirst().enumerated().map { index, stop in
            Gradient.Stop(color: Color(red: Double(stop.rgb.0), green: Double(stop.rgb.1), blue: Double(stop.rgb.2)),
                          location: Double(index) / Double(stops.count - 2))
        }
    }

    private static func color(_ v: Float) -> (Float, Float, Float, Float) {
        guard v > stops[0].value else { return (0, 0, 0, 0) }
        for (a, b) in zip(stops, stops.dropFirst()) where v <= b.value {
            let t = (v - a.value) / (b.value - a.value)
            return (a.rgb.0 + (b.rgb.0 - a.rgb.0) * t,
                    a.rgb.1 + (b.rgb.1 - a.rgb.1) * t,
                    a.rgb.2 + (b.rgb.2 - a.rgb.2) * t,
                    a.alpha + (b.alpha - a.alpha) * t)
        }
        let last = stops[stops.count - 1]
        return (last.rgb.0, last.rgb.1, last.rgb.2, last.alpha)
    }

    /// 网格里的最大概率，图例里提示当前强弱
    let maxValue: Int

    init(grid: OvationGrid, now: Date = .now) {
        maxValue = Int(grid.values.max() ?? 0)
        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: Self.maxLatitude, longitude: -180))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: -Self.maxLatitude, longitude: 180))
        let rect = MKMapRect(x: topLeft.x, y: topLeft.y,
                             width: MKMapSize.world.width, height: bottomRight.y - topLeft.y)
        boundingMapRect = rect
        image = Self.render(grid: grid, rect: rect, sun: Astro.subsolarPoint(at: now))
    }

    private static func render(grid: OvationGrid, rect: MKMapRect, sun: (latitude: Double, longitude: Double)) -> CGImage? {
        // 先做一次 3×3 加权平滑，去掉网格感
        var smooth = [Float](repeating: 0, count: 181 * 360)
        for lat in -89...89 {
            for lon in 0..<360 {
                var sum: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let w: Float = (dx == 0 ? 2 : 1) * (dy == 0 ? 2 : 1)
                        sum += w * Float(grid.value(lat: lat + dy, lon: lon + dx))
                    }
                }
                smooth[(lat + 90) * 360 + lon] = sum / 16
            }
        }

        let width = 900
        let height = Int(Double(width) * rect.height / rect.width)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        let r = Double.pi / 180
        let sinDec = sin(sun.latitude * r), cosDec = cos(sun.latitude * r)
        var cosDeltaLon = [Float](repeating: 0, count: width)
        for i in 0..<width {
            let lon: Double = -180 + (Double(i) + 0.5) * 360 / Double(width)
            cosDeltaLon[i] = Float(cos((lon - sun.longitude) * r))
        }

        for j in 0..<height {
            let mapY = rect.minY + (Double(j) + 0.5) * rect.height / Double(height)
            let lat = MKMapPoint(x: rect.minX, y: mapY).coordinate.latitude
            let sinPart = Float(sin(lat * r) * sinDec)
            let cosPart = Float(cos(lat * r) * cosDec)
            let hasAurora = abs(lat) > 30
            let fy = Float(lat + 90)
            let y0 = min(Int(fy), 179)
            let ty = fy - Float(y0)

            for i in 0..<width {
                // 白天一侧蒙一层淡淡的亮色，−12°（航海晨昏）到 0° 之间渐变
                let sunAltitude = asin(min(max(sinPart + cosPart * cosDeltaLon[i], -1), 1)) * 180 / .pi
                let day: Float = min(max((sunAltitude + 12) / 12, 0), 1)
                let veil: Float = day * 0.13
                var outR: Float = 0.80 * veil
                var outG: Float = 0.88 * veil
                var outB: Float = veil
                var outA: Float = veil

                if hasAurora {
                    let lon = -180 + (Double(i) + 0.5) * 360 / Double(width)
                    let fx = Float(lon < 0 ? lon + 360 : lon)
                    let x0 = Int(fx) % 360
                    let x1 = (x0 + 1) % 360
                    let tx = fx - Float(Int(fx))

                    let v00 = smooth[y0 * 360 + x0], v01 = smooth[y0 * 360 + x1]
                    let v10 = smooth[(y0 + 1) * 360 + x0], v11 = smooth[(y0 + 1) * 360 + x1]
                    let v = (v00 * (1 - tx) + v01 * tx) * (1 - ty) + (v10 * (1 - tx) + v11 * tx) * ty

                    let (cr, cg, cb, ca) = color(v)
                    if ca > 0 {
                        // 极光盖在昼夜层上面（预乘 alpha 的 source-over）
                        outR = cr * ca + outR * (1 - ca)
                        outG = cg * ca + outG * (1 - ca)
                        outB = cb * ca + outB * (1 - ca)
                        outA = ca + outA * (1 - ca)
                    }
                }

                guard outA > 0 else { continue }
                let p = (j * width + i) * 4
                pixels[p] = UInt8(min(outR, 1) * 255)
                pixels[p + 1] = UInt8(min(outG, 1) * 255)
                pixels[p + 2] = UInt8(min(outB, 1) * 255)
                pixels[p + 3] = UInt8(min(outA, 1) * 255)
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

final class OvationRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? OvationOverlay, let image = overlay.image else { return }
        context.interpolationQuality = .high
        UIGraphicsPushContext(context)
        UIImage(cgImage: image).draw(in: rect(for: overlay.boundingMapRect))
        UIGraphicsPopContext()
    }
}
