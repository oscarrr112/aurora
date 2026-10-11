# 极光（自用极光预报）

两个版本，功能一样，都不需要服务器和 API Key：

- **iOS**：SwiftUI，iOS 17+，无第三方依赖（`Aurora/`）
- **网页版**：纯前端，安卓、电脑浏览器都能用，可以「添加到主屏幕」当 App 用（`web/`）。推到 `main` 后由 GitHub Actions 自动部署到 GitHub Pages：https://oscarrr112.github.io/aurora/

## 功能

| 页面 | 内容 |
|---|---|
| 今晚 | 当前视野内极光概率（NOAA OVATION）、天黑时段、月亮、本地需要的 Kp 门槛、逐小时评分曲线（含云量）、3 天 Kp 曲线 |
| 去哪看 | 按出行方式（步行 4 km / 骑车 12 km / 开车 50 km）推荐具体观测点：海滩、观景点、灯塔、自然保护区、营地等，以及光污染图上的暗处；显示路程时间、头顶和极光方向地平线的光害、是否朝海，可一键导航。开车模式另外比较 150 km 内 25 个点的天气。最后是热门目的地今晚排行 |
| 地图 | 平滑的全球极光概率图 + 昼夜分界 + 目的地评分标记（去哪看页面另有一张小地图：观测点序号、出行范围圈、极光方向扇形、光污染，可全屏） |
| 太阳风 | Bz / 速度 / 密度 / Bt 实时值和曲线，预计到达时间 |
| 设置 | 当前定位或预设 / 自定义地点，后台提醒 |

## 数据来源

- NOAA SWPC：`ovation_aurora_latest.json`、`noaa-planetary-k-index-forecast.json`、`rtsw_mag_1m.json`、`rtsw_wind_1m.json`
- Open-Meteo：逐小时云量、海拔（用来排除海面、判断极光方向是不是海）
- 观测点：OpenStreetMap 数据，经 Photon 搜索服务（https://photon.komoot.io ，免费、不要 key，结果在磁盘缓存 30 天）；身边 1 km 内的公园、码头用苹果地图 MapKit 补充
- 光污染：David Lorenz《Light Pollution Atlas 2025》瓦片（https://djlorenz.github.io/astronomy/lp/ ，年度 VIIRS 数据推算的天顶天空亮度，无正式许可证，仅自用），瓦片缓存在 App 的 Caches 目录
- 日月位置、地磁纬度：本地计算（`Services/Astro.swift`、`Services/Geomag.swift`）

## 网页版

- 本地预览：`python3 -m http.server 8642 --directory web`，打开 http://localhost:8642 。地址后面加 `?at=57.64,18.30` 可以假装在某个位置
- 安卓手机：用浏览器打开网址 → 菜单 →「添加到主屏幕」/「安装应用」；定位需要 https（GitHub Pages 自带）
- 底图：Esri World Dark Gray Canvas；数据和缓存都在浏览器本地（localStorage、Cache API）

## 装到自己的 iPhone

1. 用 Xcode 打开 `Aurora.xcodeproj`
2. 选中 Aurora target → Signing & Capabilities → Team 选你的 Apple ID（没有就在 Xcode → Settings → Accounts 里添加，免费账号即可）
3. 如果提示 Bundle Identifier 冲突，把 `com.pengao.Aurora` 改成别的
4. iPhone 用线连上 Mac，在 Xcode 顶部选择你的手机，点 ▶︎ 运行
5. 第一次装需要在手机上：
   - 设置 → 隐私与安全性 → 开发者模式 → 打开（会重启）
   - 设置 → 通用 → VPN 与设备管理 → 信任你的开发者证书

> 免费 Apple ID 签名的 App **7 天后会失效**，重新连电脑点一次运行即可。付费开发者账号（99 美元/年）签名的有效期是 1 年。

## 评分算法

`Services/Forecaster.swift`：

- **视野内概率**：OVATION 网格中，300 km 内按原值，300–1000 km 线性衰减，取最大
- **逐小时评分** = Kp 相对本地门槛的可能性 × 天黑程度 × (1 − 云量) × 月光系数 × 光污染系数（`LightZone.skyFactor`）
- **极光方向**：朝本半球地磁极的方位角（`Geomag.auroraBearing`），维斯比约北偏西 17°
- **观测点光害系数** = max(脚下等级, 极光方向地平线等级) 对应的系数，看不到海再 × 0.96。地平线等级：朝极光方向 ±25°、1–25 km 采样，每远一倍降 2 级，取最差
- **观测点排序** = (今晚最高评分 + 光害系数 × 10) × (1 − 0.15 × 距离/半径)，彼此至少隔半径的 1/6；落在机场里的暗处会去掉
- **推荐点挪位**：落在村镇里的候选点，挪到半径内（附近 5 km / 目的地 15 km）最暗的陆地上
- **本地门槛**：极光卵南缘 ≈ 磁纬 66.5° − 2.05 × Kp，地平线可见再放宽约 4.5°

想调整灵敏度，直接改这几个函数里的系数。
