import MapKit
import SwiftUI

struct SkyBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.02, green: 0.03, blue: 0.10), Color(red: 0.02, green: 0.09, blue: 0.13)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(.headline).foregroundStyle(.secondary)
            }
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct ErrorBanner: View {
    let errors: [String]

    var body: some View {
        if !errors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(errors, id: \.self) { Text($0) }
            }
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

enum Fmt {
    private static let zh = Locale(identifier: "zh_CN")

    static func time(_ date: Date, _ tz: TimeZone) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: zh, timeZone: tz))
    }

    static func dayTime(_ date: Date, _ tz: TimeZone) -> String {
        date.formatted(Date.FormatStyle(locale: zh, timeZone: tz).month(.defaultDigits).day().hour(.twoDigits(amPM: .omitted)).minute())
    }

    static func hour(_ date: Date, _ tz: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return String(format: "%02d", calendar.component(.hour, from: date))
    }

    static func kp(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

enum Palette {
    static let aurora = Color(red: 0.35, green: 0.95, blue: 0.55)

    static func score(_ value: Double) -> Color {
        switch value {
        case ..<10: .gray
        case ..<30: .teal
        case ..<60: aurora
        default: .yellow
        }
    }

    static func kp(_ value: Double) -> Color {
        switch value {
        case ..<4: aurora
        case ..<5: .yellow
        case ..<6: .orange
        case ..<7: .red
        default: .purple
        }
    }
}

/// 在苹果地图里导航过去
enum Navigation {
    static func open(_ place: Place, mode: TravelMode) {
        let coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = place.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode.mapsMode])
    }
}

/// 光污染等级标签，颜色和 Lorenz 地图集一致
struct ZoneChip: View {
    let zone: LightZone

    var body: some View {
        let (r, g, b) = zone.rgb
        let light = Double(r) * 0.299 + Double(g) * 0.587 + Double(b) * 0.114 > 140
        Text(zone.name)
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(light ? .black : .white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255),
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(zone.index <= 2 ? 0.35 : 0), lineWidth: 0.5))
    }
}
