import Foundation
import Network
import Darwin

// MARK: - MiBoxService
// AirCursor APK ile TCP 9876 üzerinden iletişim kurar.
// Discovery, bağlantı ve komut gönderme tamamen birbirinden ayrılmıştır.
// APK discovery, ATV bağlantısını bloklamamalı ve engellememeli.

@MainActor
final class MiBoxService: ObservableObject {
    static let cursorPort:    UInt16 = 9876
    nonisolated static let discoveryPort: UInt16 = 9877
    nonisolated static let discoveryMagic        = "AIRCURSOR_DISCOVER"
    static let screenW               = 1920
    static let screenH               = 1080

    @Published var isConnected = false
    private(set) var cursorX = screenW / 2
    private(set) var cursorY = screenH / 2
    private(set) var atvPairingPort = 6467
    private(set) var atvRemotePort  = 6466

    private var connection: NWConnection?
    private var recvBuf    = Data()
    // MARK: - Connect

    /// TCP bağlantısı dener (2s timeout). 
    /// Retry mantığı RemoteView tarafından yönetilir.
    func connect(to ip: String) async -> Bool {
        disconnect()
        return await attemptConnect(to: ip)
    }

    func disconnect() {
        connection?.cancel(); connection = nil
        isConnected = false; recvBuf.removeAll()
    }

    private func attemptConnect(to ip: String) async -> Bool {
        connection?.cancel(); connection = nil; recvBuf.removeAll()

        let conn = NWConnection(
            host: .init(ip),
            port: .init(rawValue: Self.cursorPort)!,
            using: .tcp
        )
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
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s timeout
                guard !done else { return }; done = true
                conn.cancel(); cont.resume(returning: false)
            }
        }
    }

    // MARK: - Static APK Discovery
    // ATV discovery'den bağımsız — sadece APK'yı bulur.
    // UDP broadcast + subnet tarama kombinasyonu.

    nonisolated static func discoverAPK(timeout: TimeInterval = 3.0) async -> [String] {
        await withCheckedContinuation { cont in
            var foundIPs: [String] = []
            var done = false

            DispatchQueue.global(qos: .userInitiated).async {
                let sock = socket(AF_INET, SOCK_DGRAM, 0)
                guard sock >= 0 else { cont.resume(returning: []); return }
                defer { Darwin.close(sock) }

                var yes: Int32 = 1
                setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(sock, SOL_SOCKET, SO_REUSEADDR,  &yes, socklen_t(MemoryLayout<Int32>.size))

                // Bind to any port
                var bindAddr = sockaddr_in()
                bindAddr.sin_family      = sa_family_t(AF_INET)
                bindAddr.sin_port        = 0
                bindAddr.sin_addr.s_addr = INADDR_ANY
                withUnsafeMutablePointer(to: &bindAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }

                // 100ms receive timeout
                var tv = timeval(tv_sec: 0, tv_usec: 100_000)
                setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                let magic  = Data(discoveryMagic.utf8)
                let baddrs = broadcastAddresses()

                print("[APK-DISC] Broadcast adresleri: \(baddrs)")
                print("[APK-DISC] Magic: \(discoveryMagic) → port \(discoveryPort)")

                for addr in baddrs {
                    var dest = sockaddr_in()
                    dest.sin_family = sa_family_t(AF_INET)
                    dest.sin_port   = discoveryPort.bigEndian
                    inet_pton(AF_INET, addr, &dest.sin_addr)
                    let sent = magic.withUnsafeBytes { ptr in
                        withUnsafePointer(to: dest) { dp in
                            dp.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(sock, ptr.baseAddress, magic.count, 0, $0,
                                       socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                    print("[APK-DISC] sendto \(addr):9877 → \(sent) bytes (errno=\(errno))")
                }

                let deadline = Date().addingTimeInterval(timeout)
                var buf = [UInt8](repeating: 0, count: 4096)
                var src = sockaddr_in()
                var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                var recvCount = 0

                while Date() < deadline {
                    let n = withUnsafeMutablePointer(to: &src) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(sock, &buf, buf.count, 0, $0, &srcLen)
                        }
                    }
                    if n > 0 {
                        recvCount += 1
                        let raw = String(bytes: buf[0..<n], encoding: .utf8) ?? "<binary>"
                        print("[APK-DISC] recvfrom \(n)b: \(raw)")
                        if let json = try? JSONSerialization.jsonObject(with: Data(buf[0..<n])) as? [String: Any],
                           json["service"] as? String == "aircursor" {
                            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                            inet_ntop(AF_INET, &src.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                            let ip = String(cString: ipBuf)
                            print("[APK-DISC] ✅ APK bulundu: \(ip)")
                            if !ip.isEmpty && !foundIPs.contains(ip) { foundIPs.append(ip) }
                        } else {
                            print("[APK-DISC] ⚠️ service=aircursor değil, skip")
                        }
                    }
                }
                print("[APK-DISC] Bitti. recvCount=\(recvCount) foundIPs=\(foundIPs)")

                if !done { done = true; cont.resume(returning: foundIPs) }
            }
        }
    }

    // MARK: - Commands

    func moveCursor(dx: Int, dy: Int) {
        cursorX = max(0, min(Self.screenW, cursorX + dx))
        cursorY = max(0, min(Self.screenH, cursorY + dy))
        send(["type": "move", "dx": dx, "dy": dy])
    }

    func tap()                    { send(["type": "tap"]) }
    func sendKey(_ code: Int)     { send(["type": "key",  "code":  code]) }
    func sendText(_ text: String) { send(["type": "text", "value": text]) }
    func hideCursor()             { send(["type": "hide"]) }

    func showCursor() {
        let dx = Self.screenW / 2 - cursorX
        let dy = Self.screenH / 2 - cursorY
        send(["type": "move", "dx": dx, "dy": dy])
        Task { try? await Task.sleep(nanoseconds: 50_000_000); send(["type": "show"]) }
    }

    func setScrollMode(_ mode: Int) {
        send(["type": "scroll_mode", "mode": mode])
        if mode != 0 {
            Task { try? await Task.sleep(nanoseconds: 500_000_000); send(["type": "scroll_mode", "mode": 0]) }
        }
    }

    func sendSwipe(x1: Int, y1: Int, x2: Int, y2: Int, duration: Int = 150) {
        send(["type": "swipe", "x1": x1, "y1": y1, "x2": x2, "y2": y2, "duration": duration])
    }

    // MARK: - Private

    private func send(_ obj: [String: Any]) {
        guard isConnected, let conn = connection else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str  = String(data: data, encoding: .utf8) else { return }
        conn.send(content: Data((str + "\n").utf8), completion: .idempotent)
    }

    private func startReceive() { receive() }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { Task { @MainActor in self.handleData(data) } }
            if err == nil && !done { Task { @MainActor in self.receive() } }
            else {
                Task { @MainActor in
                    self.isConnected = false
                    // Continuous mod aktifse retry task halleder
                }
            }
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

    // MARK: - Broadcast addresses

    nonisolated static func broadcastAddresses() -> [String] {
        var addrs: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return ["255.255.255.255"] }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let ifa = ptr {
            let flags = Int32(ifa.pointee.ifa_flags)
            if ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
               flags & IFF_BROADCAST != 0,
               flags & IFF_LOOPBACK  == 0,
               let bcast = ifa.pointee.ifa_dstaddr {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                bcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    inet_ntop(AF_INET, &$0.pointee.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                }
                let s = String(cString: buf)
                if !s.isEmpty && s != "0.0.0.0" { addrs.append(s) }
            }
            ptr = ifa.pointee.ifa_next
        }
        // Subnet broadcast ekle (bazı router'lar directed broadcast'e cevap verir)
        for subnet in subnetBroadcasts() {
            if !addrs.contains(subnet) { addrs.append(subnet) }
        }
        if addrs.isEmpty { addrs.append("255.255.255.255") }
        return addrs
    }

    nonisolated private static func subnetBroadcasts() -> [String] {
        var results: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let ifa = ptr {
            let flags = Int32(ifa.pointee.ifa_flags)
            if ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
               flags & IFF_LOOPBACK == 0 {
                // IP ve subnet mask al, broadcast hesapla
                var ip: UInt32 = 0; var mask: UInt32 = 0
                ifa.pointee.ifa_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    ip = UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                ifa.pointee.ifa_netmask?.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    mask = UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                if ip != 0 && mask != 0 {
                    let bcast = (ip & mask) | (~mask)
                    let b0 = (bcast >> 24) & 0xFF
                    let b1 = (bcast >> 16) & 0xFF
                    let b2 = (bcast >>  8) & 0xFF
                    let b3 =  bcast        & 0xFF
                    results.append("\(b0).\(b1).\(b2).\(b3)")
                }
            }
            ptr = ifa.pointee.ifa_next
        }
        return results
    }
}
