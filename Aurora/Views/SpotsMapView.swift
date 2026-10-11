import CoreImage
import MapKit
import SwiftUI

/// 去哪看页面上的小地图：观测点、出行范围、极光方向和光污染，可以展开成全屏
struct SpotsMapCard: View {
    let center: Place
    let spots: [SpotForecast]
    let mode: TravelMode
    @State private var showLightPollution = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                SpotsMapView(center: center, spots: spots, mode: mode, showLightPollution: showLightPollution)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                VStack(spacing: 8) {
                    mapButton("arrow.up.left.and.arrow.down.right") { expanded = true }
                    mapButton(showLightPollution ? "lightbulb.fill" : "lightbulb", active: showLightPollution) {
                        showLightPollution.toggle()
                    }
                }
                .padding(8)
            }
            legend
        }
        .fullScreenCover(isPresented: $expanded) {
            NavigationStack {
                ZStack(alignment: .bottom) {
                    SpotsMapView(center: center, spots: spots, mode: mode, showLightPollution: showLightPollution)
                        .ignoresSafeArea(edges: .bottom)
                    legend
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
                .navigationTitle("\(mode.label)能到的观测点")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { expanded = false }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("光污染", systemImage: showLightPollution ? "lightbulb.fill" : "lightbulb") {
                            showLightPollution.toggle()
                        }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var legend: some View {
        Text("数字对应下面的列表，点开看路程和导航 · 绿色扇形是极光方向 · 虚线圈是\(mode.label) \(Int(mode.radiusKm)) km" +
             (showLightPollution ? " · 暖色是有灯光的地方，越红越亮" : " · 💡 显示光污染"))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func mapButton(_ icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(active ? .yellow : .primary)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct SpotsMapView: UIViewRepresentable {
    let center: Place
    let spots: [SpotForecast]
    let mode: TravelMode
    let showLightPollution: Bool

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        let configuration = MKStandardMapConfiguration()
        configuration.pointOfInterestFilter = MKPointOfInterestFilter(including: [.beach, .park, .nationalPark, .campground, .marina])
        map.preferredConfiguration = configuration
        map.showsCompass = true
        map.showsScale = true
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.spotID)
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.placeID)
        map.register(LabelAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.labelID)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.mode = mode

        // 光污染图层
        let hasTiles = map.overlays.contains { $0 is LightPollutionTileOverlay }
        if showLightPollution && !hasTiles {
            map.insertOverlay(LightPollutionTileOverlay(), at: 0, level: .aboveRoads)
        } else if !showLightPollution && hasTiles {
            map.removeOverlays(map.overlays.filter { $0 is LightPollutionTileOverlay })
        }

        // 范围圈、极光方向扇形，地点或出行方式变了才重画
        let frameKey = String(format: "%.4f,%.4f,%@", center.latitude, center.longitude, mode.rawValue)
        if frameKey != coordinator.frameKey {
            coordinator.frameKey = frameKey
            map.removeOverlays(map.overlays.filter { !($0 is LightPollutionTileOverlay) })
            map.removeAnnotations(map.annotations.filter { $0 is PlaceAnnotation || $0 is LabelAnnotation })

            let origin = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude)
            let circle = MKCircle(center: origin, radius: mode.radiusKm * 1000)
            let bearing = Geomag.auroraBearing(latitude: center.latitude, longitude: center.longitude)
            let length = mode.radiusKm * 1.35
            var fan = [origin]
            for offset in stride(from: -25.0, through: 25.0, by: 5) {
                let (lat, lon) = Spots.destination(from: center.latitude, center.longitude, distanceKm: length, bearing: bearing + offset)
                fan.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
            let wedge = MKPolygon(coordinates: fan, count: fan.count)
            map.addOverlays([circle, wedge], level: .aboveLabels)

            let (tipLat, tipLon) = Spots.destination(from: center.latitude, center.longitude, distanceKm: length * 0.82, bearing: bearing)
            map.addAnnotation(LabelAnnotation(
                coordinate: CLLocationCoordinate2D(latitude: tipLat, longitude: tipLon),
                text: "极光方向 · \(Spots.preciseDirection(bearing))"))
            map.addAnnotation(PlaceAnnotation(place: Place(id: center.id, name: "你在这里",
                                                           latitude: center.latitude, longitude: center.longitude)))

            let rect = circle.boundingMapRect.union(wedge.boundingMapRect)
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 30, left: 20, bottom: 20, right: 20),
                                  animated: coordinator.hasFramed)
            coordinator.hasFramed = true
        }

        let signature = spots.map { "\($0.id):\($0.place.name):\(Int($0.bestScore))" }.joined(separator: ",")
        if signature != coordinator.spotsKey {
            coordinator.spotsKey = signature
            map.removeAnnotations(map.annotations.filter { $0 is ViewingAnnotation })
            map.addAnnotations(spots.enumerated().map { ViewingAnnotation(spot: $1, rank: $0 + 1, mode: mode) })
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        static let spotID = "viewing"
        static let placeID = "origin"
        static let labelID = "label"

        var frameKey = ""
        var spotsKey = ""
        var hasFramed = false
        var mode: TravelMode = .walk

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            switch overlay {
            case let tiles as LightPollutionTileOverlay:
                let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
                renderer.alpha = 0.75
                return renderer
            case let circle as MKCircle:
                let renderer = MKCircleRenderer(circle: circle)
                renderer.strokeColor = UIColor.white.withAlphaComponent(0.45)
                renderer.lineWidth = 1.5
                renderer.lineDashPattern = [6, 5]
                return renderer
            case let wedge as MKPolygon:
                let renderer = MKPolygonRenderer(polygon: wedge)
                renderer.fillColor = UIColor(Palette.aurora).withAlphaComponent(0.08)
                renderer.strokeColor = UIColor(Palette.aurora).withAlphaComponent(0.7)
                renderer.lineWidth = 1
                return renderer
            default:
                return MKOverlayRenderer(overlay: overlay)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case let spot as ViewingAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.spotID, for: spot) as! MKMarkerAnnotationView
                view.markerTintColor = UIColor(Palette.score(spot.score))
                // 序号和下面列表对应；名字挤的时候 MapKit 会自动藏起来，放大或点开再看
                view.glyphImage = nil
                view.glyphText = "\(spot.rank)"
                view.titleVisibility = .adaptive
                view.subtitleVisibility = .hidden
                view.displayPriority = .required
                view.canShowCallout = true
                let button = UIButton(type: .system)
                button.setImage(UIImage(systemName: "arrow.triangle.turn.up.right.circle.fill"), for: .normal)
                button.tintColor = UIColor(Palette.aurora)
                button.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
                view.rightCalloutAccessoryView = button
                return view
            case let place as PlaceAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.placeID, for: place) as! MKMarkerAnnotationView
                view.markerTintColor = .systemBlue
                view.glyphImage = UIImage(systemName: "person.fill")
                view.displayPriority = .required
                view.titleVisibility = .hidden
                view.canShowCallout = false
                return view
            case let label as LabelAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.labelID, for: label) as! LabelAnnotationView
                view.configure(text: label.text)
                return view
            default:
                return nil
            }
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            if let spot = view.annotation as? ViewingAnnotation {
                Navigation.open(spot.place, mode: mode)
            }
        }
    }
}

final class ViewingAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let score: Double
    let rank: Int
    let place: Place

    init(spot: SpotForecast, rank: Int, mode: TravelMode) {
        place = spot.place
        coordinate = CLLocationCoordinate2D(latitude: spot.place.latitude, longitude: spot.place.longitude)
        title = spot.place.name.isEmpty ? spot.kind?.label : spot.place.name
        score = spot.bestScore
        self.rank = rank
        var parts = [mode.durationText(distanceKm: spot.distanceKm ?? 0), "今晚最高 \(Int(spot.bestScore)) 分"]
        if let horizon = spot.horizon, horizon.seaView { parts.append("朝海") }
        subtitle = parts.joined(separator: " · ")
    }
}

final class LabelAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let text: String

    init(coordinate: CLLocationCoordinate2D, text: String) {
        self.coordinate = coordinate
        self.text = text
    }
}

/// 地图上一段小字（极光方向）
final class LabelAnnotationView: MKAnnotationView {
    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = UIColor(Palette.aurora)
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        addSubview(label)
        displayPriority = .required
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String) {
        label.text = text
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: 0, y: 0, width: size.width + 14, height: size.height + 6)
        frame = label.frame
        centerOffset = .zero
    }
}

/// 光污染图层：从 Lorenz 地图集的 z=6 瓦片里切出对应的一块，只把有灯光的地方（4a 以上）
/// 用暖色晕开，暗处完全透明，不挡底图
final class LightPollutionTileOverlay: MKTileOverlay {
    private static let colors: [(UInt8, UInt8, UInt8, UInt8)] = LightZone.all.map { zone in
        let alpha: UInt8
        switch zone.index {
        case ..<7: alpha = 0
        case 7...8: alpha = 90
        case 9...10: alpha = 140
        default: alpha = 185
        }
        return (UInt8(zone.rgb.0), UInt8(zone.rgb.1), UInt8(zone.rgb.2), alpha)
    }

    private static let ciContext = CIContext()

    init() {
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 6
        canReplaceMapContent = false
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        Task.detached(priority: .utility) {
            result(await Self.render(path), nil)
        }
    }

    private static func render(_ path: MKTileOverlayPath) async -> Data? {
        let atlasZoom = LightPollutionStore.atlasZoom
        guard path.z >= atlasZoom else { return nil }
        let shift = path.z - atlasZoom
        let tileX = path.x >> shift, tileY = path.y >> shift
        // 这块 256 像素的地图瓦片对应地图集瓦片里从 (x0, y0) 开始、边长 span 像素的一块
        let span = Double(LightPollutionStore.atlasTileSize) / Double(1 << shift)
        let x0 = Double(path.x - (tileX << shift)) * span
        let y0 = Double(path.y - (tileY << shift)) * span
        let out = 256
        let store = LightPollutionStore.shared

        if span >= Double(out) {
            // 缩得很小：直接最近邻缩小
            guard let zones = await store.zoneBlock(tileX: tileX, tileY: tileY, srcX: Int(x0), srcY: Int(y0),
                                                    size: Int(span), outSize: out) else { return nil }
            return png(image(zones: zones, size: out))
        }

        // 放大：多取 3 像素的边，放大后高斯模糊，把一格一格的台阶晕成平滑的光斑，瓦片之间也接得上
        let margin = 3
        let bx = Int(x0.rounded(.down)) - margin, by = Int(y0.rounded(.down)) - margin
        let block = Int(span.rounded(.up)) + 2 * margin + 1
        guard let zones = await store.zoneBlock(tileX: tileX, tileY: tileY, srcX: bx, srcY: by,
                                                size: block, outSize: block),
              zones.contains(where: { Int($0) < colors.count && colors[Int($0)].3 > 0 }),
              let small = image(zones: zones, size: block) else { return nil }

        let k = Double(out) / span
        var picture = CIImage(cgImage: small)
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        if span >= 2 {
            picture = picture.clampedToExtent().applyingGaussianBlur(sigma: k * 0.9)
        }
        // CoreImage 的 y 轴朝上
        let rect = CGRect(x: (x0 - Double(bx)) * k,
                          y: (Double(block) - (y0 - Double(by)) - span) * k,
                          width: Double(out), height: Double(out))
        return png(ciContext.createCGImage(picture, from: rect))
    }

    private static func image(zones: [UInt8], size: Int) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<zones.count {
            let zone = Int(zones[i])
            guard zone < colors.count else { continue }
            let c = colors[zone]
            // 预乘 alpha
            let a = UInt16(c.3)
            rgba[i * 4] = UInt8(UInt16(c.0) * a / 255)
            rgba[i * 4 + 1] = UInt8(UInt16(c.1) * a / 255)
            rgba[i * 4 + 2] = UInt8(UInt16(c.2) * a / 255)
            rgba[i * 4 + 3] = c.3
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func png(_ image: CGImage?) -> Data? {
        image.map { UIImage(cgImage: $0).pngData() } ?? nil
    }
}
