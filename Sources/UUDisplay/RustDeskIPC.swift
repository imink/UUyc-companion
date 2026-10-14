import Darwin
import Foundation

enum RustDeskIPCError: Error, CustomStringConvertible {
    case unavailable
    case invalidResponse
    case timeout
    case system(String, Int32)

    var description: String {
        switch self {
        case .unavailable: return "RustDesk 本地服务未运行"
        case .invalidResponse: return "RustDesk IPC 返回了不支持的响应"
        case .timeout: return "RustDesk IPC 查询超时"
        case .system(let operation, let code):
            return "RustDesk IPC \(operation): \(String(cString: strerror(code)))"
        }
    }
}

enum RustDeskIPC {
    static var paths: [String] {
        ["/tmp/RustDesk-\(geteuid())/ipc", "/tmp/RustDesk/ipc"]
    }

    // RustDesk Data JSON, framed with hbb_common::BytesCodec. No config writes or service IPC.
    static let request = frame(Data(#"{"t":"VideoConnCount","c":null}"#.utf8))

    static func frame(_ payload: Data) -> Data {
        precondition(payload.count <= 4096)
        let headerSize = payload.count <= 63 ? 1 : 2
        let header = (payload.count << 2) | (headerSize - 1)
        var data = Data((0..<headerSize).map { UInt8(truncatingIfNeeded: header >> ($0 * 8)) })
        data.append(payload)
        return data
    }

    static func decode(_ data: Data) throws -> Int? {
        guard let first = data.first else { return nil }
        let headerSize = Int(first & 3) + 1
        guard data.count >= headerSize else { return nil }
        let header = (0..<headerSize).reduce(0) { $0 | (Int(data[$1]) << ($1 * 8)) }
        let length = header >> 2
        guard length > 0, length <= 4096 else { throw RustDeskIPCError.invalidResponse }
        guard data.count >= headerSize + length else { return nil }
        guard data.count == headerSize + length else { throw RustDeskIPCError.invalidResponse }
        struct Response: Decodable { let t: String; let c: Int }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data.dropFirst(headerSize))
        } catch {
            throw RustDeskIPCError.invalidResponse
        }
        guard response.t == "VideoConnCount", response.c >= 0 else {
            throw RustDeskIPCError.invalidResponse
        }
        return response.c
    }

    static func count() throws -> Int {
        for path in paths {
            do { return try count(path: path) }
            catch RustDeskIPCError.unavailable { continue }
        }
        throw RustDeskIPCError.unavailable
    }

    static func count(path: String, timeout: TimeInterval = 1) throws -> Int {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            if errno == ENOENT { throw RustDeskIPCError.unavailable }
            throw RustDeskIPCError.system("检查 socket", errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFSOCK, metadata.st_uid == geteuid() else {
            throw RustDeskIPCError.system("socket 不属于当前用户或不是 socket", EACCES)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RustDeskIPCError.system("创建 socket", errno) }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                         socklen_t(MemoryLayout.size(ofValue: noSigPipe))) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            throw RustDeskIPCError.system("设置 socket", errno)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw RustDeskIPCError.system("socket 路径过长", ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let code = errno
            if code == ENOENT || code == ECONNREFUSED { throw RustDeskIPCError.unavailable }
            guard code == EINPROGRESS else { throw RustDeskIPCError.system("连接", code) }
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: error))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else {
                throw RustDeskIPCError.system("检查连接", errno)
            }
            if error == ECONNREFUSED { throw RustDeskIPCError.unavailable }
            guard error == 0 else { throw RustDeskIPCError.system("连接", error) }
        }
        var sent = 0
        while sent < request.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            let size = request.withUnsafeBytes {
                Darwin.send(fd, $0.baseAddress!.advanced(by: sent), request.count - sent, 0)
            }
            if size < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard size > 0 else { throw RustDeskIPCError.system("发送查询", errno) }
            sent += size
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let size = recv(fd, &buffer, buffer.count, 0)
            if size < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard size > 0 else { throw RustDeskIPCError.invalidResponse }
            response.append(contentsOf: buffer.prefix(size))
            if let count = try decode(response) { return count }
        }
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw RustDeskIPCError.timeout }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(ceil(remaining * 1000)))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw RustDeskIPCError.system("等待响应", errno) }
            guard result > 0 else { throw RustDeskIPCError.timeout }
            guard descriptor.revents & Int16(POLLNVAL) == 0 else {
                throw RustDeskIPCError.system("socket 已关闭", EBADF)
            }
            return
        }
    }
}
