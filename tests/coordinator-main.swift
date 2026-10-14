import Foundation

enum Log { static func info(_ message: String) {} }
enum PhysicalDisplays { static let available = true }
enum UUReader {
    static let isTrusted = true
    static var names: [String] = []
    static func readControllers() -> [String]? { names }
    static func showMainWindow() {}
}
final class UUMonitor {
    var connected = false
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    func start() {}
}

final class DisplayManager {
    var shouldDisablePhysical: () -> Bool = { false }
    var current: DeviceConfig?
    var isActive: Bool { current != nil }
    var wedged = false
    var physicalOff = false
    var removals = 0
    var restores = 0
    var disables = 0
    func recoverIfNeeded() {}
    func create(_ config: DeviceConfig) { current = config }
    func remove(completion: (() -> Void)? = nil) {
        current = nil
        removals += 1
        completion?()
    }
    func restorePhysicalNow(override: Bool = true) { restores += 1 }
    func disablePhysicalIfNeeded() { disables += 1 }
    func matches(_ config: DeviceConfig) -> Bool {
        guard let current else { return false }
        return current.width == config.width && current.height == config.height && current.hiDPI == config.hiDPI
    }
}

private final class Probe {
    private let lock = NSLock()
    private var result: Result<Int, Error> = .success(0)
    func set(_ value: Result<Int, Error>) { lock.lock(); result = value; lock.unlock() }
    func read() throws -> Int {
        lock.lock(); let result = self.result; lock.unlock()
        return try result.get()
    }
}

@main struct CoordinatorTests {
    static func main() throws {
        let directory = URL(fileURLWithPath: "/tmp/uu-coordinator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(directory: directory)
        let uu = DeviceConfig(name: "same name", kind: .tablet, width: 2360, height: 1640)
        var rd = DeviceConfig(name: "same name", kind: .tablet, width: 2532, height: 1170)
        store.config.devices = [uu]
        store.config.rustDeskProfile = rd
        store.config.disablePhysical = true
        let probe = Probe()
        let rustDesk = RustDeskMonitor(enabled: { store.config.rustDeskProfile != nil },
                                      readCount: { try probe.read() })
        let monitor = UUMonitor()
        let display = DisplayManager()
        let coordinator = Coordinator(store: store, monitor: monitor, rustDesk: rustDesk, display: display)
        coordinator.start()
        func run() { RunLoop.main.run(until: Date().addingTimeInterval(0.6)) }
        run()
        precondition(display.current == nil && !coordinator.connected, "No authorized desktop must not create a screen")
        probe.set(.success(1)); run()
        precondition(display.current == rd && coordinator.connected)
        monitor.connected = true
        UUReader.names = [uu.name]
        coordinator.handleConnect()
        precondition(display.current == rd, "UU connecting cannot replace another active owner")
        probe.set(.success(0)); run()
        precondition(display.current == uu, "RustDesk disconnect must transfer ownership to UU")
        probe.set(.success(1)); run()
        precondition(display.current == uu)
        monitor.connected = false
        coordinator.handleDisconnect()
        precondition(display.current == rd, "UU disconnect cannot remove RustDesk's virtual screen")
        monitor.connected = true
        UUReader.names = ["unconfigured"]
        coordinator.handleConnect()
        precondition(display.current == rd, "Unknown UU device cannot remove RustDesk's virtual screen")
        monitor.connected = false
        coordinator.handleDisconnect()
        coordinator.setPaused(true)
        precondition(display.current == nil)
        coordinator.setPaused(false)
        precondition(display.current == rd)
        rd.width = 2796
        store.config.rustDeskProfile = rd
        coordinator.configChanged()
        precondition(display.current == rd)
        precondition(coordinator.physicalDisableAllowed)
        probe.set(.failure(RustDeskIPCError.timeout)); run()
        precondition(display.current == rd && display.restores > 0 && !coordinator.physicalDisableAllowed)
        let disables = display.disables
        probe.set(.success(1)); run()
        precondition(coordinator.physicalDisableAllowed && display.disables > disables)
        store.config.rustDeskProfile = nil
        coordinator.configChanged()
        precondition(display.current == nil && !coordinator.connected)
        let reloaded = ConfigStore(directory: directory)
        precondition(reloaded.config.devices == [uu] && reloaded.config.rustDeskProfile == nil)
        print("PASS: real coordinator UU/RustDesk ownership transfer, unknown UU, pause/resume, config updates, physical recovery, persistence")
    }
}
