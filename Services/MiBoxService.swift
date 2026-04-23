import Foundation
import Network
import Darwin

@MainActor
final class MiBoxService: ObservableObject {
    static let cursorPort:    UInt16 = 9876
    static let discoveryPort: UInt16 = 9877
    static let discoveryMagic = "AIRCURSOR_DISCOVER"
    static let screenW = 1920
    static let screenH = 1080

    @Published var isConnected = false
    private(set) var cursorX = screenW / 2
    private(set) var cursorY = screenH / 2
    private(set) var atvPairingPort = 6467
    private(set) var atvRemotePort  = 6466

    private var connection: NWConnection?
    private var recvBuf = Data()

    // MARK: - Static discovery

    static func discoverDevices(timeout: Duration = .seconds(2)) async -> [[String: Any]] {
        await withCheckedContinuation { cont in
            var results: [[String: Any]] = []
            var done = false

            DispatchQueue.global().async {
                let sock = socket(AF_INET, SOCK_DGRAM, 0)
                guard sock >= 0 else { cont.resume(returning: []); return }
                defer { Darwin.close(sock) }

                var yes: Int32 = 1
                setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(sock, SOL_SOCKET, SO_REUSEADDR,  &yes, socklen_t(MemoryLayout<Int32>.size))

                var bindAddr = sockaddr_in()
                bindAddr.sin_family = sa_family_t(AF_INET)
                bindAddr.sin_port   = 0
                bindAddr.sin_addr.s_addr = INADDR_ANY
                withUnsafeMutablePointer(to: &bindAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }

                var tv = timeval(tv_sec: 0, tv_usec: 100_000)
                setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                let magic = Data(discoveryMagic.utf8)
                for addr in broadcastAddresses() {
                    var dest = sockaddr_in()
                    dest.sin_family = sa_family_t(AF_INET)
                    dest.sin_port   = discoveryPort.bigEndian
                    inet_pton(AF_INET, addr, &dest.sin_addr)
                    magic.withUnsafeBytes { ptr in
                        withUnsafePointer(to: dest) { dp in
                            dp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(sock, ptr.baseAddress, magic.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }

                let deadline = Date().addingTimeInterval(timeout.seconds)
                var buf = [UInt8](repeating: 0, count: 4096)
                var src = sockaddr_in(); var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                while Date() < deadline {
                    let n = withUnsafeMutablePointer(to: &src) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(sock, &buf, buf.count, 0, $0, &srcLen)
                        }
                    }
                    if n > 0,
                       let json = try? JSONSerialization.jsonObject(with: Data(buf[0..<n])) as? [String: Any],
                       json["service"] as? String == "aircursor" {
                        var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        inet_ntop(AF_INET, &src.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                        var device = json
                        device["ip"] = String(cString: ipBuf)
                        results.append(device)
                    }
                }
                if !done { done = true; cont.resume(returning: results) }
            }
        }
    }

    private static func broadcastAddresses() -> [String] {
        var addrs: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return ["255.255.255.255"] }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let ifa = ptr {
            if ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
               Int32(ifa.pointee.ifa_flags) & IFF_BROADCAST != 0,
               let bcast = ifa.pointee.ifa_dstaddr {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                bcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    inet_ntop(AF_INET, &$0.pointee.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                }
                let s = String(cString: buf)
                if !s.isEmpty { addrs.append(s) }
            }
            ptr = ifa.pointee.ifa_next
        }
        return addrs.isEmpty ? ["255.255.255.255"] : addrs
    }

    // MARK: - Connection

    func connect(to ip: String) async -> Bool {
        disconnect()
        let conn = NWConnection(host: .init(ip), port: .init(rawValue: Self.cursorPort)!, using: .tcp)
        connection = conn
        return await withCheckedContinuation { cont in
            var done = false
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !done else { return }; done = true
                    Task { @MainActor in
                        self?.isConnected = true
                        self?.startReceive()
                        cont.resume(returning: true)
                    }
                case .failed, .cancelled:
                    guard !done else { return }; done = true
                    Task { @MainActor in self?.isConnected = false }
                    cont.resume(returning: false)
                default: break
                }
            }
            conn.start(queue: .global())
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard !done else { return }; done = true
                conn.cancel(); cont.resume(returning: false)
            }
        }
    }

    func disconnect() {
        connection?.cancel(); connection = nil
        isConnected = false; recvBuf.removeAll()
    }

    // MARK: - Commands

    func moveCursor(dx: Int, dy: Int) {
        cursorX = max(0, min(Self.screenW, cursorX + dx))
        cursorY = max(0, min(Self.screenH, cursorY + dy))
        send(["type": "move", "dx": dx, "dy": dy])
    }

    func tap()                  { send(["type": "tap"]) }
    func sendKey(_ code: Int)   { send(["type": "key",  "code":  code]) }
    func sendText(_ text: String) { send(["type": "text", "value": text]) }
    func hideCursor()           { send(["type": "hide"]) }

    func showCursor() {
        let dx = Self.screenW / 2 - cursorX
        let dy = Self.screenH / 2 - cursorY
        send(["type": "move", "dx": dx, "dy": dy])
        Task { try? await Task.sleep(for: .milliseconds(50)); send(["type": "show"]) }
    }

    func setScrollMode(_ mode: Int) {
        send(["type": "scroll_mode", "mode": mode])
        if mode != 0 {
            Task { try? await Task.sleep(for: .milliseconds(500)); send(["type": "scroll_mode", "mode": 0]) }
        }
    }

    func sendSwipe(x1: Int, y1: Int, x2: Int, y2: Int, duration: Int = 150) {
        send(["type": "swipe", "x1": x1, "y1": y1, "x2": x2, "y2": y2, "duration": duration])
    }

    // MARK: - Private

    private func send(_ obj: [String: Any]) {
        guard isConnected, let conn = connection else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        conn.send(content: Data((str + "\n").utf8), completion: .idempotent)
    }

    private func startReceive() { receive() }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { Task { @MainActor in self.handleData(data) } }
            if err == nil && !done { Task { @MainActor in self.receive() } }
            else { Task { @MainActor in self.isConnected = false } }
        }
    }

    private func handleData(_ data: Data) {
        recvBuf.append(data)
        while let nl = recvBuf.range(of: Data([0x0A])) {
            let line = recvBuf[..<nl.lowerBound]
            recvBuf.removeSubrange(..<nl.upperBound)
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                if let x = json["x"] as? Int { cursorX = x }
                if let y = json["y"] as? Int { cursorY = y }
                if let p = json["atvPairingPort"] as? Int { atvPairingPort = p }
                if let r = json["atvRemotePort"]  as? Int { atvRemotePort  = r }
            }
        }
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) * 1e-18 }
}
