import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAdd = false

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section("地点") {
                    placeRow(id: Place.currentID, name: "当前位置", detail: "使用定位", icon: "location.fill")
                    ForEach(Place.presets) { place in
                        placeRow(id: place.id, name: place.name, detail: coordinateText(place), icon: "mappin")
                    }
                }

                Section {
                    ForEach(model.customPlaces) { place in
                        placeRow(id: place.id, name: place.name, detail: coordinateText(place), icon: "star")
                    }
                    .onDelete { model.removeCustomPlaces(at: $0) }
                    Button("添加地点…", systemImage: "plus") { showingAdd = true }
                } header: {
                    Text("我的地点")
                }

                Section {
                    Toggle("极光提醒", isOn: $model.notifyEnabled)
                        .onChange(of: model.notifyEnabled) { _, enabled in
                            if enabled {
                                Task {
                                    if await !BackgroundRefresh.requestPermission() { model.notifyEnabled = false }
                                    BackgroundRefresh.schedule()
                                }
                            }
                        }
                    if model.notifyEnabled {
                        Stepper("视野内概率 ≥ \(model.notifyThreshold)%", value: $model.notifyThreshold, in: 5...80, step: 5)
                        Button("发送测试通知（5 秒后）") {
                            Task {
                                await BackgroundRefresh.notify(title: "测试通知", body: "提醒功能正常 ✨", delay: 5)
                            }
                        }
                    }
                } header: {
                    Text("提醒")
                } footer: {
                    Text("App 在后台时由 iOS 决定检查时机，可能几十分钟到几小时才一次，不保证及时。天黑、概率达标且云量 < 85% 才会提醒，3 小时内最多一次。")
                }

                Section("数据来源") {
                    LabeledContent("极光概率、Kp、太阳风", value: "NOAA SWPC")
                    LabeledContent("云量、海拔", value: "Open-Meteo")
                    LabeledContent("光污染", value: "Lorenz Atlas 2025")
                    LabeledContent("观测点", value: "OpenStreetMap · 苹果地图")
                    LabeledContent("日月位置", value: "本地计算")
                }
            }
            .scrollContentBackground(.hidden)
            .background(SkyBackground())
            .navigationTitle("设置")
            .sheet(isPresented: $showingAdd) {
                AddPlaceView()
            }
        }
    }

    private func placeRow(id: String, name: String, detail: String, icon: String) -> some View {
        Button {
            model.select(id)
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading) {
                        Text(name).foregroundStyle(.primary)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: icon).foregroundStyle(Palette.aurora)
                }
                Spacer()
                if model.selectedPlaceID == id {
                    Image(systemName: "checkmark").foregroundStyle(Palette.aurora)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func coordinateText(_ place: Place) -> String {
        String(format: "%.2f°%@, %.2f°%@",
               abs(place.latitude), place.latitude >= 0 ? "N" : "S",
               abs(place.longitude), place.longitude >= 0 ? "E" : "W")
    }
}

private struct AddPlaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var latitude = ""
    @State private var longitude = ""

    private var lat: Double? { Double(latitude).flatMap { (-90...90).contains($0) ? $0 : nil } }
    private var lon: Double? { Double(longitude).flatMap { (-180...180).contains($0) ? $0 : nil } }

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name)
                TextField("纬度（北正南负，如 69.65）", text: $latitude)
                    .keyboardType(.numbersAndPunctuation)
                TextField("经度（东正西负，如 18.96）", text: $longitude)
                    .keyboardType(.numbersAndPunctuation)
                Section {
                    Text("可以在苹果地图里长按一个点，下方会显示坐标。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("添加地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let lat, let lon {
                            model.addPlace(name: name.isEmpty ? "我的地点" : name, latitude: lat, longitude: lon)
                            dismiss()
                        }
                    }
                    .disabled(lat == nil || lon == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
