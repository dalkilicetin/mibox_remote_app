import Foundation
import Network
import Darwin

@MainActor
final class DeviceDiscovery: ObservableObject {
    @Published var devices: [DiscoveredDevice] = []
    @Published var isScanning = false
    @Published var status = ""

    private var browser1: NWBrowser?
    private var browser2: NWBrowser?
    private var scanTask: Task<Void, Never>?

    func startScan() {
        guard !isScanning else { return }
        scanTask?.cancel()
        scanTask = Task { await performScan() }
    }

    func stop() { scanTask?.cancel(); stopBrowsers(); isScanning = false }

    // MARK: - Scan pipeline

    private func performScan() async {
        isScanning = true; devices = []; status = "Adım 1: mDNS taranıyor..."

        // UDP APK discovery (parallel, short)
        let udpResults = await MiBoxService.discoverAPK(timeout: 3.0)
        // discoverAPK artık sadece IP listesi döndürüyor
        // Port bilgisi APK TCP bağlantısından alınacak (MiBoxService.handleData)
        let apkIPs = Set(udpResults)
        let udpPorts: [String: (pairing: Int, remote: Int)] = [:]

        // mDNS
        let mdnsIPs = await scanMDNS(apkIPs: apkIPs, udpPorts: udpPorts)
        var foundIPs = mdnsIPs

        // TCP sweep if nothing found
        if devices.isEmpty {
            status = "Adım 2: TCP port tarama..."
            let tcpIPs = await scanTCP(apkIPs: apkIPs, udpPorts: udpPorts)
            foundIPs.formUnion(tcpIPs)
        }

        isScanning = false
        status = devices.isEmpty
            ? "Cihaz bulunamadı. TV açık ve aynı Wi-Fi'da mı?"
            : "\(devices.count) cihaz bulundu"
    }

    private func scanMDNS(apkIPs: Set<String>, udpPorts: [String: (pairing: Int, remote: Int)]) async -> Set<String> {
        await withCheckedContinuation { (cont: CheckedContinuation<Set<String>, Never>) in
            var foundIPs = Set<String>()
            var resumed = false
            func finish() { guard !resumed else { return }; resumed = true; cont.resume(returning: foundIPs) }

            let params = NWParameters(); params.includePeerToPeer = false
            let b1 = NWBrowser(for: .bonjour(type: "_androidtvremote._tcp",  domain: nil), using: params)
            let b2 = NWBrowser(for: .bonjour(type: "_androidtvremote2._tcp", domain: nil), using: params)
            browser1 = b1; browser2 = b2

            let handle: (NWBrowser.Result) -> Void = { [weak self] result in
                guard let self else { return }
                if case let .service(name, type, domain, _) = result.endpoint {
                    Task { @MainActor in
                        let host = "\(name).\(type)\(domain)"
                        if let ip = await resolve(hostname: host), !foundIPs.contains(ip) {
                            foundIPs.insert(ip)
                            let ports = udpPorts[ip]
                            self.addDevice(DiscoveredDevice(
                                ip: ip,
                                hasCert: KeychainHelper.hasCert(certKey: ip),
                                hasApk: apkIPs.contains(ip),
                                pairingPort: ports?.pairing ?? 6467,
                                remotePort:  ports?.remote  ?? 6466
                            ))
                        }
                    }
                }
            }

            b1.browseResultsChangedHandler = { results, _ in results.forEach { handle($0) } }
            b2.browseResultsChangedHandler = { results, _ in results.forEach { handle($0) } }
            b1.start(queue: .global()); b2.start(queue: .global())

            Task {
                try? await Task.sleep(for: .seconds(3))
                b1.cancel(); b2.cancel(); finish()
            }
        }
    }

    private func scanTCP(apkIPs: Set<String>, udpPorts: [String: (pairing: Int, remote: Int)]) async -> Set<String> {
        let subnets = localSubnets()
        let allIPs  = subnets.flatMap { s in (1...254).map { "\(s).\($0)" } }

        let batchSize = 40
        var idx = 0
        while idx < allIPs.count {
            let batch = Array(allIPs[idx..<min(idx + batchSize, allIPs.count)])
            idx += batchSize
            await withTaskGroup(of: String?.self) { group in
                for ip in batch {
                    group.addTask {
                        guard await tcpProbe(ip: ip, port: 6467, timeoutSec: 0.5) else { return nil }
                        return ip
                    }
                }
                for await ip in group {
                    if let ip {
                        let ports = udpPorts[ip]
                        await MainActor.run {
                            self.addDevice(DiscoveredDevice(
                                ip: ip,
                                hasCert: KeychainHelper.hasCert(certKey: ip),
                                hasApk: apkIPs.contains(ip),
                                pairingPort: ports?.pairing ?? 6467,
                                remotePort:  ports?.remote  ?? 6466
                            ))
                        }
                    }
                }
            }
        }
        return []
    }

    private func addDevice(_ d: DiscoveredDevice) {
        if let i = devices.firstIndex(where: { $0.ip == d.ip }) { devices[i] = d }
        else { devices.append(d) }
    }

    private func stopBrowsers() {
        browser1?.cancel(); browser2?.cancel()
        browser1 = nil; browser2 = nil
    }
}

// MARK: - Helpers

private func localSubnets() -> [String] {
    var subnets = Set<String>()
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return [] }
    defer { freeifaddrs(ifaddr) }
    var ptr = ifaddr
    while let ifa = ptr {
        if ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) {
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            ifa.pointee.ifa_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                inet_ntop(AF_INET, &$0.pointee.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            }
            let ip = String(cString: buf)
            let parts = ip.split(separator: ".")
            if parts.count == 4, ip != "127.0.0.1" {
                subnets.insert("\(parts[0]).\(parts[1]).\(parts[2])")
            }
        }
        ptr = ifa.pointee.ifa_next
    }
    return Array(subnets)
}

private func tcpProbe(ip: String, port: Int, timeoutSec: Double) async -> Bool {
    await withCheckedContinuation { cont in
        let conn = NWConnection(host: .init(ip), port: .init(rawValue: UInt16(port))!, using: .tcp)
        var done = false
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:   guard !done else { return }; done = true; conn.cancel(); cont.resume(returning: true)
            case .failed, .cancelled: guard !done else { return }; done = true; cont.resume(returning: false)
            default: break
            }
        }
        conn.start(queue: .global())
        Task {
            try? await Task.sleep(for: .seconds(timeoutSec))
            guard !done else { return }; done = true; conn.cancel(); cont.resume(returning: false)
        }
    }
}

private func resolve(hostname: String) async -> String? {
    await withCheckedContinuation { cont in
        DispatchQueue.global().async {
            let host = CFHostCreateWithName(nil, hostname as CFString).takeRetainedValue()
            var resolved = DarwinBoolean(false)
            CFHostStartInfoResolution(host, .addresses, nil)
            guard let addresses = CFHostGetAddressing(host, &resolved)?.takeUnretainedValue() as? [Data] else {
                cont.resume(returning: nil); return
            }
            for addr in addresses {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                addr.withUnsafeBytes { ptr in
                    getnameinfo(ptr.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                                socklen_t(addr.count), &buf, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST)
                }
                let ip = String(cString: buf)
                if !ip.isEmpty && ip.contains(".") { cont.resume(returning: ip); return }
            }
            cont.resume(returning: nil)
        }
    }
}
