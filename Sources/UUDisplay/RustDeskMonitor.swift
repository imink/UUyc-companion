import Foundation

final class RustDeskMonitor {
    var onChange: (() -> Void)?
    private(set) var connected = false
    private(set) var healthy = false
    private(set) var errorText: String?
    private var timer: Timer?
    private var readInFlight = false
    private var goneSince: Date?
    private let queue = DispatchQueue(label: "uudisplay.rustdesk-reader", qos: .utility)
    private let enabled: () -> Bool
    private let readCount: () throws -> Int

    init(enabled: @escaping () -> Bool = { ConfigStore.shared.config.rustDeskProfile != nil },
         readCount: @escaping () throws -> Int = { try RustDeskIPC.count() }) {
        self.enabled = enabled
        self.readCount = readCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        guard enabled() else {
            update(connected: false, healthy: false, error: nil)
            goneSince = nil
            return
        }
        guard !readInFlight else { return }
        readInFlight = true
        let read = readCount
        let started = Date()
        queue.async { [weak self] in
            let result = Result { try read() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readInFlight = false
                guard self.enabled() else { return }
                let freshResult = Date().timeIntervalSince(started) <= 2
                    ? result : .failure(RustDeskIPCError.timeout)
                switch freshResult {
                case .success(let count):
                    self.goneSince = nil
                    self.update(connected: count > 0, healthy: true, error: nil)
                case .failure(RustDeskIPCError.unavailable):
                    self.goneSince = self.goneSince ?? Date()
                    self.update(connected: self.connected && Date().timeIntervalSince(self.goneSince!) < 2,
                                healthy: false, error: RustDeskIPCError.unavailable.description)
                case .failure(let error):
                    // Unknown state is not a confirmed disconnect. Keep the virtual screen,
                    // but stop disabling physical displays until a valid snapshot returns.
                    self.update(connected: self.connected, healthy: false, error: String(describing: error))
                }
            }
        }
    }

    private func update(connected: Bool, healthy: Bool, error: String?) {
        guard self.connected != connected || self.healthy != healthy || errorText != error else { return }
        if errorText != error, let error { Log.info(error) }
        if self.connected != connected { Log.info("RustDesk 桌面连接：\(connected ? "已授权" : "已结束")") }
        self.connected = connected
        self.healthy = healthy
        errorText = error
        onChange?()
    }
}
