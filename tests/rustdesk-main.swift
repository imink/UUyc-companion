import Darwin
import Foundation

enum Log { static func info(_ message: String) {} }
enum PhysicalDisplays {
    static var pending: String? { nil }
    static func restore(reason: String) {}
}
enum UUMonitor { static func overlayPresent() -> Bool { false } }

private final class Probe {
    private let lock = NSLock()
    private var result: Result<Int, Error> = .success(0)
    func set(_ result: Result<Int, Error>) { lock.lock(); self.result = result; lock.unlock() }
    func read() throws -> Int {
        lock.lock()
        let result = self.result
        lock.unlock()
        return try result.get()
    }
}

@main struct RustDeskTests {
    static func main() throws {
        try testProtocol()
        try testSocket()
        try testConfigAndSelection()
        try testHeartbeat()
        testMonitor()
        print("PASS: RustDesk framing, fragmented Unix IPC, timeout, strict responses, old config, shared ownership, monitor transitions, watchdog heartbeat")
    }

    static func testProtocol() throws {
        let request = Data(#"{"t":"VideoConnCount","c":null}"#.utf8)
        precondition(RustDeskIPC.request == Data([UInt8(request.count << 2)]) + request)
        for count in [0, 1, 2, 100] {
            let data = RustDeskIPC.frame(Data("{\"t\":\"VideoConnCount\",\"c\":\(count)}".utf8))
            for end in 0..<data.count {
                let result = try RustDeskIPC.decode(Data(data.prefix(end)))
                precondition(result == nil)
            }
            let result = try RustDeskIPC.decode(data)
            precondition(result == count)
        }
        let long = RustDeskIPC.frame(Data(("{\"t\":\"VideoConnCount\",\"c\":3}" + String(repeating: " ", count: 80)).utf8))
        precondition(long.first! & 3 == 1)
        let count = try RustDeskIPC.decode(long)
        precondition(count == 3)
        for json in [
            #"{"t":"VideoConnCount","c":-1}"#,
            #"{"t":"VideoConnCount","c":true}"#,
            #"{"t":"VideoConnCount","c":null}"#,
            #"{"t":"VideoConnCount","c":"1"}"#,
            #"{"t":"ConnCount","c":1}"#,
            #"{"t":"VideoConnCount"}"#,
            "not JSON"
        ] {
            do {
                _ = try RustDeskIPC.decode(RustDeskIPC.frame(Data(json.utf8)))
                preconditionFailure("Invalid response accepted: \(json)")
            } catch RustDeskIPCError.invalidResponse {}
        }
        for data in [Data([0]), Data([3, 255, 255, 255])] {
            do {
                _ = try RustDeskIPC.decode(data)
                preconditionFailure("Invalid frame accepted")
            } catch RustDeskIPCError.invalidResponse {}
        }
    }

    static func testSocket() throws {
        let directory = URL(fileURLWithPath: "/tmp/uu-rd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ipc").path
        func server(delay: Bool) -> DispatchGroup {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            precondition(fd >= 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            precondition(bound == 0 && listen(fd, 1) == 0)
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                defer { close(fd); group.leave() }
                let peer = accept(fd, nil, nil)
                precondition(peer >= 0)
                defer { close(peer) }
                var request = Data()
                var buffer = [UInt8](repeating: 0, count: 64)
                while request.count < RustDeskIPC.request.count {
                    let size = recv(peer, &buffer, buffer.count, 0)
                    precondition(size > 0)
                    request.append(contentsOf: buffer.prefix(size))
                }
                precondition(request == RustDeskIPC.request, "Only read-only VideoConnCount may be sent")
                if delay { usleep(300_000); return }
                let response = RustDeskIPC.frame(Data(#"{"t":"VideoConnCount","c":2}"#.utf8))
                for byte in response {
                    var byte = byte
                    precondition(send(peer, &byte, 1, 0) == 1)
                    usleep(1000)
                }
            }
            return group
        }
        let valid = server(delay: false)
        let count = try RustDeskIPC.count(path: path)
        precondition(count == 2)
        valid.wait()
        precondition(unlink(path) == 0)
        let delayed = server(delay: true)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try RustDeskIPC.count(path: path, timeout: 0.1)
            preconditionFailure("IPC must time out")
        } catch RustDeskIPCError.timeout {}
        precondition(ProcessInfo.processInfo.systemUptime - started < 0.25)
        delayed.wait()
        precondition(unlink(path) == 0)
        do {
            _ = try RustDeskIPC.count(path: path)
            preconditionFailure("Missing socket must be unavailable")
        } catch RustDeskIPCError.unavailable {}
        try Data().write(to: URL(fileURLWithPath: path))
        do {
            _ = try RustDeskIPC.count(path: path)
            preconditionFailure("Regular files must not be opened as IPC")
        } catch RustDeskIPCError.system(_, let code) { precondition(code == EACCES) }
    }

    static func testConfigAndSelection() throws {
        let old = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"devices":[],"paused":false}"#.utf8))
        precondition(old.rustDeskProfile == nil)
        let uu = DeviceConfig(name: "RustDesk", kind: .tablet, width: 2360, height: 1640)
        let rd = DeviceConfig(name: "RustDesk", kind: .tablet, width: 2532, height: 1170)
        let selected = DisplaySelection.choose(uu: uu, rustDesk: rd, current: .rustDesk)
        precondition(selected?.owner == .rustDesk && selected?.config == rd, "Names cannot conflate ownership")
        precondition(DisplaySelection.choose(uu: uu, rustDesk: rd, current: .uu)?.config == uu)
        precondition(DisplaySelection.choose(uu: nil, rustDesk: rd, current: .uu)?.config == rd)
        precondition(DisplaySelection.choose(uu: uu, rustDesk: nil, current: .rustDesk)?.config == uu)
        precondition(DisplaySelection.choose(uu: nil, rustDesk: nil, current: .rustDesk) == nil)
        let invalid = DeviceConfig(name: "unset", kind: .tablet, width: 0, height: 0)
        precondition(DisplaySelection.choose(uu: invalid, rustDesk: rd, current: .uu)?.config == rd)
        let computer = DeviceConfig(name: "computer", kind: .computer, width: 1920, height: 1080)
        precondition(DisplaySelection.choose(uu: computer, rustDesk: nil, current: nil) == nil)
        for size in [319, 16385] {
            let cfg = DeviceConfig(name: "bad", kind: .tablet, width: size, height: 1080)
            precondition(DisplaySelection.choose(uu: nil, rustDesk: cfg, current: nil) == nil)
        }
        var config = old
        config.devices = [uu]
        config.rustDeskProfile = rd
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        precondition(decoded.devices == [uu] && decoded.rustDeskProfile == rd)
    }

    static func testMonitor() {
        let probe = Probe()
        var enabled = true
        let monitor = RustDeskMonitor(enabled: { enabled }, readCount: { try probe.read() })
        monitor.start()
        func run(_ seconds: Double = 0.6) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        run()
        precondition(!monitor.connected && monitor.healthy)
        probe.set(.success(1)); run()
        precondition(monitor.connected && monitor.healthy)
        probe.set(.success(2)); run()
        precondition(monitor.connected)
        probe.set(.failure(RustDeskIPCError.system("permission", EACCES))); run()
        precondition(monitor.connected && !monitor.healthy && monitor.errorText != nil)
        probe.set(.success(1)); run()
        precondition(monitor.connected && monitor.healthy && monitor.errorText == nil)
        probe.set(.success(0)); run()
        precondition(!monitor.connected, "Last authorized desktop disconnect must release ownership")
        probe.set(.success(1)); run()
        probe.set(.failure(RustDeskIPCError.unavailable)); run(3)
        precondition(!monitor.connected, "Missing service must release ownership after grace period")
        probe.set(.success(1)); run()
        enabled = false
        monitor.refresh()
        precondition(!monitor.connected && monitor.errorText == nil)

        let slow = RustDeskMonitor(enabled: { true }, readCount: {
            Thread.sleep(forTimeInterval: 2.2)
            return 1
        })
        slow.start()
        run(2.4)
        precondition(!slow.connected && !slow.healthy, "Stale results must not create a new session")
    }

    static func testHeartbeat() throws {
        let url = URL(fileURLWithPath: "/tmp/uu-heartbeat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        precondition(!Heartbeat.sessionActive(pid: getpid(), at: url))
        Heartbeat.beatSession(active: true, to: url)
        precondition(Heartbeat.sessionActive(pid: getpid(), at: url))
        precondition(!Heartbeat.sessionActive(pid: getpid() + 1, at: url))
        precondition(!Heartbeat.sessionActive(pid: getpid(), at: url, now: Date().addingTimeInterval(4)))
        Heartbeat.beatSession(active: false, to: url)
        precondition(!Heartbeat.sessionActive(pid: getpid(), at: url))
        try Data("invalid".utf8).write(to: url)
        precondition(!Heartbeat.sessionActive(pid: getpid(), at: url))
    }
}
