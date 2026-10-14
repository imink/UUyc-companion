// 设备配置面板（设置窗口第一栏）：只列出从 UU「全部设备」导入的设备，为平板和手机填写虚拟屏分辨率，改动自动保存
import AppKit
import SwiftUI

final class WizardModel: ObservableObject {
    @Published var rows: [DeviceConfig] = [] {
        didSet { if !loading { scheduleSave() } }
    }
    @Published var message: String?
    @Published var trusted = UUReader.isTrusted
    @Published var collapsedComputers = false
    @Published var collapsedMobiles = false
    @Published var rustDeskEnabled = false {
        didSet { if !loading { scheduleSave() } }
    }
    @Published var rustDeskError: String?
    @Published var rustDeskProfile = DeviceConfig(name: "RustDesk", kind: .tablet, width: 0, height: 0) {
        didSet { if !loading { scheduleSave() } }
    }

    /// 自动保存后回调（设置窗口借此重新应用配置、显示「已自动保存」）
    var onSaved: (() -> Void)?

    private let store = ConfigStore.shared
    private var loading = false
    private var saveWork: DispatchWorkItem?

    init() { load() }

    var computers: [Binding<DeviceConfig>] { bindings { $0.inComputerGroup } }
    var mobiles: [Binding<DeviceConfig>] { bindings { !$0.inComputerGroup } }

    private func bindings(_ keep: @escaping (DeviceConfig) -> Bool) -> [Binding<DeviceConfig>] {
        rows.filter(keep).map { row in
            Binding(get: { [weak self] in self?.rows.first { $0.name == row.name } ?? row },
                    set: { [weak self] new in
                        guard let self, let i = self.rows.firstIndex(where: { $0.name == row.name }) else { return }
                        self.rows[i] = new
                    })
        }
    }

    /// 从 UU远程「全部设备」导入；读到设备就以它为准并自动保存，读不到则保留已保存的列表
    func load() {
        loading = true
        defer { loading = false }
        trusted = UUReader.isTrusted
        rows = store.config.devices
        rustDeskEnabled = store.config.rustDeskProfile != nil
        if let profile = store.config.rustDeskProfile { rustDeskProfile = profile }
        guard trusted else {
            message = "需要先完成授权，才能读到 UU远程 里的设备。授权后点「导入设备列表」。"
            return
        }
        if !UUReader.hasMainWindow { UUReader.showMainWindow(); Thread.sleep(forTimeInterval: 1) }
        let found = (UUReader.readDevices() ?? []).filter { !$0.isSelf }
        guard !found.isEmpty else {
            message = "没有读到设备列表。请打开UU远程，点击「全部设备」页面，再回到本软件，点「导入设备列表」。"
            return
        }
        // 已有设置保留；新设备：电脑不指定分辨率，平板/手机的分辨率留空由用户填写
        rows = found.map { d in
            var cfg = store.device(named: d.name)
                ?? DeviceConfig.make(name: d.name, kind: Presets.guessKind(name: d.name, isComputerGroup: d.isComputerGroup))
            cfg.uuComputer = d.isComputerGroup
            cfg.platform = d.platform
            return cfg
        }
        message = "已从 UU远程 导入 \(found.count) 台设备（不含这台 Mac），并已自动保存。"
        save()
    }

    /// 输入分辨率时逐字触发，稍等再保存，避免按半截数字建虚拟屏
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func save() {
        saveWork?.cancel()
        rustDeskError = nil
        if !rustDeskEnabled {
            store.config.rustDeskProfile = nil
        } else if rustDeskProfile.hasSize || (rustDeskProfile.width == 0 && rustDeskProfile.height == 0) {
            store.config.rustDeskProfile = rustDeskProfile
        } else {
            rustDeskError = "RustDesk 尺寸尚未保存：宽高必须都在 320～16384 像素之间，或同时留空。"
        }
        // 宽高要么都没填，要么都在合理范围内（避免填到一半就保存）
        if rows.allSatisfy({ $0.kind == .computer || $0.hasSize || ($0.width == 0 && $0.height == 0) }) {
            store.config.devices = rows
        } else {
            message = "UU 设备尺寸尚未保存：宽高必须都在 320～16384 像素之间，或同时留空。"
        }
        onSaved?()
    }
}

// MARK: - UU 风格的设备图标

/// 简笔安卓机器人（SF Symbols 没有安卓图标）
struct AndroidGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 18
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            var head = Path()
            head.addArc(center: p(9, 8), radius: 6 * s, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            head.closeSubpath()
            ctx.fill(head, with: .color(.white))
            var antenna = Path()
            antenna.move(to: p(5.6, 3.6)); antenna.addLine(to: p(4.2, 1.4))
            antenna.move(to: p(12.4, 3.6)); antenna.addLine(to: p(13.8, 1.4))
            ctx.stroke(antenna, with: .color(.white), style: StrokeStyle(lineWidth: 1.1 * s, lineCap: .round))
            for x in [6.6, 11.4] as [CGFloat] {
                ctx.fill(Path(ellipseIn: CGRect(origin: p(x - 0.8, 4.9), size: CGSize(width: 1.6 * s, height: 1.6 * s))), with: .color(.accentColor))
            }
            ctx.fill(Path(roundedRect: CGRect(origin: p(3, 9), size: CGSize(width: 12 * s, height: 7.5 * s)), cornerRadius: 1.8 * s), with: .color(.white))
        }
    }
}

struct DeviceIcon: View {
    let cfg: DeviceConfig

    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.accentColor)
            .frame(width: 34, height: 34)
            .overlay(glyph.foregroundStyle(.white))
    }

    @ViewBuilder private var glyph: some View {
        switch cfg.platform ?? "" {
        case "macos", "ios": Image(systemName: "apple.logo").font(.system(size: 17, weight: .medium))
        case "android": AndroidGlyph().frame(width: 20, height: 20)
        case "windows": Image(systemName: "square.grid.2x2.fill").font(.system(size: 15))
        default: Image(systemName: cfg.inComputerGroup ? "desktopcomputer" : "ipad.and.iphone").font(.system(size: 15))
        }
    }
}

// MARK: - 设备卡片

struct DeviceRow: View {
    @Binding var cfg: DeviceConfig

    /// 两档：无须定义（=电脑，不调整）/ 自定义分辨率
    private var customBinding: Binding<Bool> {
        Binding(get: { cfg.kind != .computer }, set: { custom in
            if custom {
                cfg.kind = Presets.guessKind(name: cfg.name, isComputerGroup: false)
            } else {
                cfg.kind = .computer
            }
        })
    }

    /// 0 显示为空（显示灰字「宽」「高」）
    private func sizeBinding(_ key: WritableKeyPath<DeviceConfig, Int>) -> Binding<Int?> {
        Binding(get: { cfg[keyPath: key] == 0 ? nil : cfg[keyPath: key] }, set: { cfg[keyPath: key] = $0 ?? 0 })
    }

    var body: some View {
        HStack(spacing: 12) {
            DeviceIcon(cfg: cfg)
            VStack(alignment: .leading, spacing: 2) {
                Text(cfg.name).font(.system(size: 14)).lineLimit(1)
                if cfg.kind != .computer && !cfg.hasSize {
                    Text("填写后才会准备虚拟屏").font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            }
            .frame(width: 160, alignment: .leading)
            Picker("", selection: customBinding) {
                Text("不指定分辨率").tag(false)
                Text("自定义分辨率").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 190)

            if cfg.kind == .computer {
                Text("不指定虚拟屏分辨率，由远程软件决定").foregroundStyle(.secondary)
            } else {
                TextField("宽", value: sizeBinding(\.width), format: .number.grouping(.never))
                    .frame(width: 62).multilineTextAlignment(.trailing)
                Text("×")
                TextField("高", value: sizeBinding(\.height), format: .number.grouping(.never))
                    .frame(width: 62)
                Text("像素").foregroundStyle(.secondary)
                Toggle("高清（HiDPI）", isOn: $cfg.hiDPI)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08)))
    }
}

/// 仿 UU「全部设备」的分组标题：⌄ 电脑 3
struct DeviceGroupHeader: View {
    let title: String
    let count: Int
    @Binding var collapsed: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(count)").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }
}

struct WizardView: View {
    @ObservedObject var model: WizardModel
    var openPermissions: (() -> Void)?
    /// 嵌入设置窗口时使用面板标题与自适应宽度
    var embedded = false
    var savedHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("为UU远程中已登录的设备指定虚拟屏的分辨率").font(.title2.bold())
                Spacer()
                if savedHint { Label("已自动保存", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Button("导入设备列表") { model.load() }
            }
            if let m = model.message { Text(m).foregroundStyle(.secondary) }
            if !model.trusted {
                Button("去授权…") { openPermissions?() }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("自动匹配 RustDesk 已授权的桌面连接", isOn: $model.rustDeskEnabled)
                    Text("为 RustDesk 预先填写尺寸。所有入站桌面连接共用此档；不能自动读取 iPhone 视口或识别控制端。文件传输、等待授权等不会触发。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.rustDeskEnabled {
                        DeviceRow(cfg: $model.rustDeskProfile)
                        if let error = model.rustDeskError {
                            Text(error).font(.caption).foregroundStyle(.orange)
                        }
                        Text("需要支持 VideoConnCount 的官方 RustDesk（源码核对：1.4.3 和当前版本）。连接后在 RustDesk 中选择虚拟屏；IPC 不可用时菜单栏会显示原因。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    let computers = model.computers
                    if !computers.isEmpty {
                        DeviceGroupHeader(title: "电脑", count: computers.count, collapsed: $model.collapsedComputers)
                        if !model.collapsedComputers {
                            ForEach(computers, id: \.wrappedValue.id) { DeviceRow(cfg: $0) }
                        }
                    }
                    let mobiles = model.mobiles
                    if !mobiles.isEmpty {
                        DeviceGroupHeader(title: "手机/平板", count: mobiles.count, collapsed: $model.collapsedMobiles)
                        if !model.collapsedMobiles {
                            Text("💡 不知道屏幕分辨率？问问 AI：「<我的设备名称及型号>的屏幕物理分辨率是多少？」把查到的数字填进来，单位是像素，大的数字填在左边。")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(mobiles, id: \.wrappedValue.id) { DeviceRow(cfg: $0) }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(minHeight: 220)
        }
        .padding(embedded ? 24 : 20)
        .frame(minWidth: embedded ? nil : 860, minHeight: 460)
    }
}
