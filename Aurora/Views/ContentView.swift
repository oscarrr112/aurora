import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        TabView(selection: $model.tab) {
            TonightView()
                .tabItem { Label("今晚", systemImage: "moon.stars") }
                .tag(AppTab.tonight)
            SpotsView()
                .tabItem { Label("去哪看", systemImage: "binoculars") }
                .tag(AppTab.spots)
            AuroraMapScreen()
                .tabItem { Label("地图", systemImage: "map") }
                .tag(AppTab.map)
            SolarWindView()
                .tabItem { Label("太阳风", systemImage: "wind") }
                .tag(AppTab.wind)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .tint(Palette.aurora)
        .task {
            // 前台时每 10 分钟自动刷新
            await model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                await model.refresh()
            }
        }
    }
}

/// 刷新按钮，几个页面共用
struct RefreshButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isLoading {
            ProgressView()
        } else {
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
    }
}
