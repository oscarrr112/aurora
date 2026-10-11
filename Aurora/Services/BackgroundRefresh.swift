import BackgroundTasks
import Foundation
import UserNotifications

/// 后台检查极光并发本地通知。iOS 决定什么时候运行（通常几十分钟到几小时一次），不保证及时。
enum BackgroundRefresh {
    static let taskID = "com.pengao.Aurora.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        schedule()
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Prefs.notifyEnabled),
              let lat = defaults.object(forKey: Prefs.lastLatitude) as? Double,
              let lon = defaults.object(forKey: Prefs.lastLongitude) as? Double else { return }

        let now = Date.now
        if let last = defaults.object(forKey: Prefs.lastNotified) as? Date, now.timeIntervalSince(last) < 3 * 3600 { return }
        guard Astro.sunAltitude(at: now, latitude: lat, longitude: lon) < -10,
              let grid = try? await NOAAClient.fetchOvation() else { return }

        let visible = Forecaster.nowcast(grid: grid, latitude: lat, longitude: lon).visible
        guard visible >= Prefs.threshold else { return }

        var body = "视野内极光概率 \(visible)%"
        if let clouds = try? await WeatherClient.fetchClouds(latitude: lat, longitude: lon),
           let hour = clouds.hour(near: now) {
            guard hour.effective < 85 else { return }
            body += "，云量 \(Int(hour.effective))%"
        }

        await notify(title: "极光来了，出门看看！", body: body)
        defaults.set(now, forKey: Prefs.lastNotified)
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func notify(title: String, body: String, delay: TimeInterval? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
