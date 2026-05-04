import Foundation
import Network
import Darwin

@MainActor
final class DeviceDiscovery: ObservableObject {
    @Published var devices: [DiscoveredDevice] = []
    @Published var isScanning = false
    @Published var status = ""

    // mDNS browser'lar sürekli açık kalır — kopma anında hazır liste
    private var browser1: NWBrowser?
    private var browser2: NWBrowser?
    private var browsersStarted = false

    private var scanTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var monitorTask: Task<Void, Never>?

    var onNetworkChange: (() -> Void)?

    // mDNS ile bulunan IP'ler — sürekli güncellenir
    private var mdnsIPs: Set<String> = []

    // MARK: - Public API

    func startScan() {
        guard !isScanning else { return }
        cancelScanInternals()
        startBrowsersIfNeeded()
        scanTask = Task { await performScan(silent: false) }
    }

    func startScanSilent(onDeviceFound: ((DiscoveredDevice) -> Void)? = nil) {
        cancelScanInternals()
        startBrowsersIfNeeded()
        scanTask = Task { await performScan(silent: true, onDeviceFound: onDeviceFound) }
    }

    func stop() {
        cancelScanInternals()
        isScanning = false
        // Browser'ları kapatma — sürekli dinlesin
    }

    // MARK: - mDNS Browser (sürekli çalışır)

    func startBrowsersIfNeeded() {
        guard !browsersStarted else { return }
        browsersStarted = true

        let params = NWParameters()
        params.includePeerToPeer = false

        let b1 = NWBrowser(for: .bonjour(type: "_androidtvremote._tcp",  domain: nil), using: params)
        let b2 = NWBrowser(for: .bonjour(type: "_androidtvremote2._tcp", domain: nil), using: params)
        browser1 = b1
        browser2 = b2

        let handle: (NWBrowser.Result) -> Void = { [weak self] result in
            guard let self else { return }
            if case let .service(name, type, domain, interface) = result.endpoint {
                Task { @MainActor [self] in
                    // DNS-only resolve — TCP bağlantısı kurma
                    let ep = NWEndpoint.service(name: name, type: type,
                                                domain: domain, interface: interface)
                    if let ip = await self.resolveViaDNS(ep) {
                        if self.mdnsIPs.insert(ip).inserted {
                            self.status = "mDNS: \(ip) bulundu"
                            let device = self.addOrUpdate(ip: ip, hasApk: false)
                            _ = device
                        }
                    }
                }
            }
        }

        // Servis kaybolunca IP listesinden çıkar
        let handleChanged: ([NWBrowser.Result], NWBrowser.Result.Change) -> Void = { [weak self] results, change in
            results.forEach { handle($0) }
            // Removed servisleri temizle
            if case let .removed(result) = change {
                if case let .service(name, _, _, _) = result.endpoint {
                    Task { @MainActor [self] in
                        self?.mdnsIPs = self?.mdnsIPs.filter { !$0.contains(name) } ?? []
                    }
                }
            }
        }

        b1.browseResultsChangedHandler = { results, change in
            results.forEach { handle($0) }
        }
        b2.browseResultsChangedHandler = { results, change in
            results.forEach { handle($0) }
        }

        b1.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state {
                Task { @MainActor in self?.status = "mDNS hata: \(err)" }
            }
        }

        b1.start(queue: .global(qos: .userInitiated))
        b2.start(queue: .global(qos: .userInitiated))
    }

    func stopBrowsers() {
        browser1?.cancel(); browser2?.cancel()
        browser1 = nil; browser2 = nil
        browsersStarted = false
    }

    // MARK: - DNS-only resolve (TCP bağlantısı YOK)
    // NWConnection ile sadece path/endpoint bilgisini al, gerçek bağlantı kurma

    private func resolveViaDNS(_ endpoint: NWEndpoint) async -> String? {
        await withCheckedContinuation { cont in
            // Sadece DNS lookup için minimal TCP params
            let params = NWParameters.tcp
            params.prohibitedInterfaceTypes = []

            let conn = NWConnection(to: endpoint, using: params)
            var done = false

            conn.stateUpdateHandler = { state in
                switch state {
                case .preparing:
                    // preparing aşamasında path.remoteEndpoint dolu olabilir
                    if let path = conn.currentPath,
                       case let .hostPort(host, _) = path.remoteEndpoint {
                        let raw = "\(host)".trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        if raw.contains(".") && !done {
                            done = true
                            conn.cancel()
                            cont.resume(returning: raw)
                            return
                        }
                    }
                case .ready:
                    if !done {
                        done = true
                        if let path = conn.currentPath,
                           case let .hostPort(host, _) = path.remoteEndpoint {
                            var ip = "\(host)".trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                            if !ip.contains(".") { ip = "" }
                            conn.cancel()
                            cont.resume(returning: ip.isEmpty ? nil : ip)
                        } else {
                            conn.cancel()
                            cont.resume(returning: nil)
                        }
                    }
                case .failed, .cancelled:
                    if !done {
                        done = true
                        cont.resume(returning: nil)
                    }
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))

            // 3s timeout
            Task {
                try? await Task.sleep(for: .seconds(3))
                guard !done else { return }
                done = true
                conn.cancel()
                cont.resume(returning: nil)
            }
        }
    }

    // MARK: - NWPathMonitor

    func startMonitoringNetwork() {
        stopMonitoringNetwork()
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        var firstUpdate = true
        monitorTask = Task {
            let stream = AsyncStream<NWPath> { cont in
                monitor.pathUpdateHandler = { cont.yield($0) }
                monitor.start(queue: .global(qos: .background))
            }
            for await path in stream {
                guard !Task.isCancelled else { break }
                if firstUpdate { firstUpdate = false; continue }
                if path.status == .satisfied {
                    await MainActor.run { self.onNetworkChange?() }
                }
            }
        }
    }

    func stopMonitoringNetwork() {
        monitorTask?.cancel(); monitorTask = nil
        pathMonitor?.cancel(); pathMonitor = nil
    }

    // MARK: - Scan pipeline

    private func performScan(silent: Bool, onDeviceFound: ((DiscoveredDevice) -> Void)? = nil) async {
        if !silent { isScanning = true; status = "Taranıyor..." }
        devices = []
        mdnsIPs = []

        // UDP (APK keşfi) paralel
        async let udpTask = MiBoxService.discoverAPK(timeout: 3.0)

        // mDNS sonuçları için 4s bekle — browser zaten çalışıyor
        try? await Task.sleep(for: .seconds(4))
        let apkIPs = await Set(udpTask)

        guard !Task.isCancelled else { if !silent { isScanning = false }; return }

        for ip in apkIPs { addOrUpdate(ip: ip, hasApk: true) }

        // mDNS bulamadıysa TCP sweep
        if mdnsIPs.isEmpty {
            if !silent { status = "mDNS bulunamadı — TCP taranıyor..." }
            await scanTCP(apkIPs: apkIPs, onDeviceFound: onDeviceFound)
        } else {
            // mDNS ile bulunanları ekle
            for ip in mdnsIPs {
                let device = addOrUpdate(ip: ip, hasApk: apkIPs.contains(ip))
                onDeviceFound?(device)
            }
        }

        for ip in apkIPs { addOrUpdate(ip: ip, hasApk: true) }

        if !silent {
            isScanning = false
            status = devices.isEmpty
                ? "Cihaz bulunamadı. TV açık ve aynı Wi-Fi'da mı?"
                : "\(devices.count) cihaz bulundu"
        }
    }

    // MARK: - TCP Sweep

    private func scanTCP(apkIPs: Set<String>, onDeviceFound: ((DiscoveredDevice) -> Void)?) async {
        let subnets = localSubnets()
        guard !subnets.isEmpty else { return }

        let allIPs = subnets.flatMap { s in (1...254).map { "\(s).\($0)" } }
        let batchSize = 50
        var idx = 0

        while idx < allIPs.count {
            guard !Task.isCancelled else { return }
            let batch = Array(allIPs[idx ..< min(idx + batchSize, allIPs.count)])
            idx += batchSize

            await withTaskGroup(of: (String, Int)?.self) { group in
                for ip in batch {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        if await tcpProbe(ip: ip, port: 6467, timeoutSec: 0.5) { return (ip, 6467) }
                        if await tcpProbe(ip: ip, port: 6466, timeoutSec: 0.5) { return (ip, 6466) }
                        return nil
                    }
                }
                for await result in group {
                    guard let (ip, _) = result else { continue }
                    await MainActor.run {
                        let device = self.addOrUpdate(ip: ip, hasApk: apkIPs.contains(ip))
                        onDeviceFound?(device)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func cancelScanInternals() {
        scanTask?.cancel(); scanTask = nil
    }

    @discardableResult
    private func addOrUpdate(ip: String, hasApk: Bool) -> DiscoveredDevice {
        if let i = devices.firstIndex(where: { $0.ip == ip }) {
            if hasApk { devices[i].hasApk = true }
            return devices[i]
        } else {
            let d = DiscoveredDevice(
                ip: ip,
                hasCert: KeychainHelper.hasCert(certKey: ip),
                hasApk: hasApk,
                pairingPort: 6467,
                remotePort: 6466
            )
            devices.append(d)
            return d
        }
    }
}

// MARK: - TCP probe

private func tcpProbe(ip: String, port: Int, timeoutSec: Double) async -> Bool {
    await withCheckedContinuation { cont in
        let conn = NWConnection(
            host: .init(ip),
            port: .init(rawValue: UInt16(port))!,
            using: .tcp
        )
        var done = false
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard !done else { return }
                done = true; conn.cancel(); cont.resume(returning: true)
            case .failed, .cancelled:
                guard !done else { return }
                done = true; cont.resume(returning: false)
            default: break
            }
        }
        conn.start(queue: .global(qos: .background))
        Task {
            try? await Task.sleep(for: .seconds(timeoutSec))
            guard !done else { return }
            done = true; conn.cancel(); cont.resume(returning: false)
        }
    }
}

// MARK: - Local subnets

func localSubnets() -> [String] {
    var subnets = Set<String>()
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return [] }
    defer { freeifaddrs(ifaddr) }
    var ptr = ifaddr
    while let ifa = ptr {
        let flags = Int32(ifa.pointee.ifa_flags)
        if ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
           flags & IFF_LOOPBACK == 0,
           flags & IFF_UP != 0 {
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
