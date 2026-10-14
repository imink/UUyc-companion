// 连入/断开 → 选设备配置 → 建屏/还原
// 只处理 UU 设备列表里、且填了分辨率的设备；读不到名字或认不出就不调整，交给 UU远程 自己处理
import AppKit

final class Coordinator {
    let monitor: UUMonitor
    let rustDesk: RustDeskMonitor
    let display: DisplayManager
    private let store: ConfigStore

    init(store: ConfigStore = .shared, monitor: UUMonitor = UUMonitor(),
         rustDesk: RustDeskMonitor? = nil, display: DisplayManager = DisplayManager()) {
        self.store = store
        self.monitor = monitor
        self.rustDesk = rustDesk ?? RustDeskMonitor(enabled: { store.config.rustDeskProfile != nil })
        self.display = display
    }

    /// 状态变化时通知菜单栏刷新
    var onChange: (() -> Void)?

    private(set) var controllerName: String?
    private var namePoll: Timer?
    private var connectedAt = Date.distantPast
    private var openedUUWindow = false
    private var uuConfig: DeviceConfig?
    private var selected: DisplaySelection.Selection?

    /// 调试：模拟连入的控制端名称（不读 UU）
    var simulatedName: String?

    var connected: Bool { monitor.connected || simulatedName != nil || rustDesk.connected }

    func start() {
        display.shouldDisablePhysical = { [weak self] in self?.physicalDisableAllowed ?? false }
        display.recoverIfNeeded()
        monitor.onConnect = { [weak self] in self?.handleConnect() }
        monitor.onDisconnect = { [weak self] in self?.handleDisconnect() }
        rustDesk.onChange = { [weak self] in
            guard let self else { return }
            if self.rustDesk.connected && !self.rustDesk.healthy {
                self.display.restorePhysicalNow(override: false)
            }
            self.reconcile()
        }
        monitor.start()
        rustDesk.start()
    }

    /// 开关打开且私有 API 可用时关闭物理屏；看门狗是可选兜底（快捷键 ⌃⌥⌘9 始终可用）
    var physicalDisableAllowed: Bool {
        store.config.shouldDisablePhysical && PhysicalDisplays.available
            && (!rustDesk.connected || rustDesk.healthy)
    }

    var statusText: String {
        if display.wedged { return "⛔️ 屏幕设置无响应，请重启 Mac" }
        if store.config.paused { return "虚拟屏已暂停：连接时不做调整" }
        let warning = rustDesk.errorText.map { " · \($0)" } ?? ""
        guard connected else { return "等待其它设备连接中\(warning)" }
        let who = selected?.config.name ?? controllerName ?? (rustDesk.connected ? "RustDesk" : "未知设备")
        if let c = display.current, display.isActive {
            return "\(who) 已连接 · 虚拟屏已匹配 \(c.sizeLabel)\(display.physicalOff ? " · 物理屏幕已软关闭" : "")\(warning)"
        }
        return "\(who) 已连接 · 虚拟屏没有调整\(warning)"
    }

    // MARK: - 事件

    func handleConnect() {
        connectedAt = Date()
        controllerName = nil
        openedUUWindow = false
        onChange?()
        guard !store.config.paused else { return }
        if pollName() { return }
        namePoll?.invalidate()
        namePoll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            if self.pollName() { t.invalidate() }
        }
    }

    func handleDisconnect() {
        namePoll?.invalidate()
        namePoll = nil
        uuConfig = nil
        controllerName = nil
        reconcile()
    }

    /// 返回 true 表示已拿到名称、无需继续轮询
    private func pollName() -> Bool {
        guard monitor.connected || simulatedName != nil, !store.config.paused else { return true }
        let elapsed = Date().timeIntervalSince(connectedAt)

        if let name = simulatedName ?? readControllerName() {
            resolve(name)
            return true
        }
        if elapsed >= 30 {
            Log.info("30 秒内未读到控制端名称，停止等待")
            return true
        }
        return false
    }

    private func readControllerName() -> String? {
        guard UUReader.isTrusted else { return nil }
        switch UUReader.readControllers() {
        case .none:
            // 主窗口没开：打开一次 UU 主界面再读
            if !openedUUWindow {
                openedUUWindow = true
                Log.info("UU 主窗口未打开，尝试打开以读取控制端名称")
                UUReader.showMainWindow()
            }
            return nil
        case .some(let names):
            return names.first
        }
    }

    private func resolve(_ name: String) {
        controllerName = name
        Log.info("控制端：\(name)")
        let cfg: DeviceConfig?
        if let known = store.device(named: name) {
            cfg = known
        } else if simulatedName != nil {
            // 调试模拟：未配置的名称用固定测试尺寸
            cfg = DeviceConfig(name: name, kind: .tablet, width: 2360, height: 1640)
        } else {
            cfg = nil
            Log.info("「\(name)」不在设备列表里，不调整")
        }
        uuConfig = cfg
        reconcile()
    }

    private func reconcile() {
        defer { onChange?() }
        guard !store.config.paused else { return }
        selected = DisplaySelection.choose(uu: uuConfig,
                                           rustDesk: rustDesk.connected ? store.config.rustDeskProfile : nil,
                                           current: selected?.owner)
        let cfg = selected?.config
        guard let cfg, cfg.kind != .computer, cfg.hasSize else {
            display.remove()
            return
        }
        if display.matches(cfg) {
            display.disablePhysicalIfNeeded()
            return
        }
        display.create(cfg)
    }

    // MARK: - 菜单操作

    func setPaused(_ paused: Bool) {
        store.config.paused = paused
        if paused {
            namePoll?.invalidate()
            selected = nil
            display.remove()
        } else if monitor.connected || simulatedName != nil {
            handleConnect()
        }
        reconcile()
        onChange?()
    }

    /// 配置变更后，若正在被控则按新配置重新应用
    func configChanged() {
        rustDesk.refresh()
        if connected, !store.config.paused {
            if let name = controllerName { resolve(name) }
            else if monitor.connected || simulatedName != nil { handleConnect() }
            reconcile()
        }
        onChange?()
    }

    /// 快捷键 ⌃⌥⌘9 / 菜单：立即恢复物理屏
    func restorePhysical() {
        Log.info("手动恢复物理屏")
        display.restorePhysicalNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func setDisablePhysical(_ on: Bool) {
        store.config.disablePhysical = on
        if on { display.disablePhysicalIfNeeded() } else { display.restorePhysicalNow(override: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func shutdown(completion: @escaping () -> Void) {
        display.remove(completion: completion)
    }
}
