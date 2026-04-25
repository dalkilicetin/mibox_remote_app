import SwiftUI
import Network
import Darwin

struct SetupView: View {
    @StateObject private var discovery = DeviceDiscovery()
    @State private var destination: NavDest?
    @State private var showManualEntry = false
    @State private var manualIP = ""
    @State private var isAutoConnecting = false

    // Fix: connection lock — race condition önleme
    // cache connect ve scan result aynı anda destination set etmesin
    private var connectionLock = ConnectionLock()

    enum NavDest: Identifiable, Hashable {
        case pairing(DiscoveredDevice)
        case remote(DiscoveredDevice, MiBoxService?)

        var id: String {
            switch self {
            case .pairing(let d): return "pair-\(d.ip)"
            case .remote(let d, _): return "remote-\(d.ip)"
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case .pairing(let d):
                hasher.combine(0)
                hasher.combine(d)
            case .remote(let d, let s):
                hasher.combine(1)
                hasher.combine(d)
                if let s = s {
                    hasher.combine(ObjectIdentifier(s))
                }
            }
        }

        static func == (lhs: NavDest, rhs: NavDest) -> Bool {
            switch (lhs, rhs) {
            case (.pairing(let a), .pairing(let b)):
                return a == b
            case (.remote(let a, let sa), .remote(let b, let sb)):
                return a == b && sa === sb
            default:
                return false
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.appBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    headerView(geo: geo)
                    if discovery.isScanning {
                        ProgressView().progressViewStyle(.linear).tint(.redAccent)
                            .padding(.horizontal, geo.size.width * 0.06).padding(.bottom, 8)
                    }
                    deviceList
                        .frame(maxHeight: .infinity)
                        .layoutPriority(1)
                    bottomBar(geo: geo)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .fullScreenCover(item: $destination) { dest in
            switch dest {
            case .pairing(let d):
                PairingView(device: d) { success, newCertKey in
                    if success {
                        var updated = d
                        if let key = newCertKey, !key.isEmpty, key != d.ip {
                            updated.mac = key
                        }
                        KeychainHelper.saveStr(updated.certKey, key: "mibox_certkey")
                        destination = .remote(updated, nil)
                    } else {
                        destination = nil
                    }
                }
            case .remote(let d, let svc):
                RemoteView(device: d, apkService: svc)
                    .interactiveDismissDisabled(true)  // swipe down ile kapanmasın
            }
        }
        .onAppear {
            // Fix 4: network değişimini dinle
            discovery.onNetworkChange = {
                // Wi-Fi değişti — cache geçersiz, yeniden tara
                Task { await tryAutoConnect() }
            }
            discovery.startMonitoringNetwork()
            Task { await tryAutoConnect() }
        }
        .onDisappear {
            discovery.stop()
            discovery.stopMonitoringNetwork()
        }
        .navigationBarHidden(true)
        .alert("Manuel IP Gir", isPresented: $showManualEntry) {
            TextField("192.168.x.x", text: $manualIP)
                .keyboardType(.numbersAndPunctuation)
            Button("Bağlan") { connectManual() }
            Button("İptal", role: .cancel) { }
        }
    }

    @ViewBuilder
    private func headerView(geo: GeometryProxy) -> some View {
        VStack(spacing: geo.size.height * 0.01) {
            Image(systemName: "tv")
                .font(.system(size: min(geo.size.width * 0.13, 52)))
                .foregroundColor(.redAccent)
            Text("Mi Box Remote").font(.title.bold()).foregroundColor(.white)
            if isAutoConnecting {
                HStack(spacing: 8) {
                    ProgressView().progressViewStyle(.circular).scaleEffect(0.7).tint(.redAccent)
                    Text("Son cihaza bağlanılıyor...").font(.caption).foregroundColor(.redAccent)
                }
            } else {
                Text(discovery.status).font(.caption).foregroundColor(.gray).multilineTextAlignment(.center)
            }
        }
        .padding(.top, geo.size.height * 0.04)
        .padding(.bottom, geo.size.height * 0.02)
        .padding(.horizontal, geo.size.width * 0.05)
    }

    private var deviceList: some View {
        Group {
            if discovery.devices.isEmpty && !discovery.isScanning {
                VStack(spacing: 12) {
                    Image(systemName: "tv.slash").font(.system(size: 48)).foregroundColor(.gray)
                    Text("Cihaz bulunamadı").foregroundColor(.gray)
                    Text("TV açık ve aynı Wi-Fi'da mı?").font(.caption).foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(discovery.devices) { device in
                            DeviceCard(device: device,
                                onConnect: { connectTo(device) },
                                onRepair:  { repairDevice(device) })
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func bottomBar(geo: GeometryProxy) -> some View {
        HStack(spacing: geo.size.width * 0.025) {
            Button(action: { discovery.startScan() }) {
                Label(discovery.isScanning ? "Aranıyor..." : "Yeniden Tara",
                      systemImage: "arrow.clockwise")
                    .foregroundColor(.redAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, geo.size.height * 0.018)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.redAccent))
            }
            .disabled(discovery.isScanning)

            Button(action: {
                manualIP = KeychainHelper.loadStr("mibox_ip") ?? ""
                showManualEntry = true
            }) {
                Label("Manuel IP", systemImage: "pencil")
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, geo.size.height * 0.018)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray))
            }
        }
        .padding(.horizontal, geo.size.width * 0.04)
        .padding(.bottom, geo.size.height * 0.03)
        .padding(.top, geo.size.height * 0.01)
    }

    // MARK: - Actions

    private func connectTo(_ device: DiscoveredDevice) {
        if device.hasCert {
            launchRemote(device)
        } else {
            destination = .pairing(device)
        }
    }

    private func repairDevice(_ device: DiscoveredDevice) {
        // Önce autoconnect'i durdur — race condition önleme
        discovery.stop()
        Task {
            // Lock'u al — artık hiçbir paralel akış destination set edemez
            _ = await connectionLock.tryAcquire()
            KeychainHelper.deleteCertAndKey(certKey: device.certKey)
            isAutoConnecting = false
            destination = .pairing(device)
        }
    }

    private func launchRemote(_ device: DiscoveredDevice) {
        KeychainHelper.saveStr(device.ip, key: "mibox_ip")
        KeychainHelper.saveStr(device.certKey, key: "mibox_certkey")
        // APK bağlantısı RemoteView içinde yönetiliyor (connectContinuous).
        // SetupView'da APK probe yapmıyoruz — hız ve doğruluk için.
        destination = .remote(device, nil)
    }

    // MARK: - Auto-connect

    /// Uygulama açılışında optimistic connect + parallel scan stratejisi:
    ///
    /// 1. IP + subnet mask ile gerçek network adresi karşılaştırılır (naif /24 prefix değil).
    ///    Uyuşmuyorsa (farklı Wi-Fi / VPN) cache denenmez, anında scan başlar.
    ///
    /// 2. Subnet uyuşuyorsa paralel başlar:
    ///    - Cache IP'ye 2.5sn TCP dene (TV wake-up için yeterli süre)
    ///    - Arka planda scan sessizce çalışsın
    ///
    /// 3. ConnectionLock ile race condition önlenir:
    ///    Cache kazanırsa scan result'ları yoksayılır, tersi de geçerli.
    private func tryAutoConnect() async {
        guard let savedIP = KeychainHelper.loadStr("mibox_ip"),
              !savedIP.isEmpty else {
            discovery.startScan(); return
        }

        let certKey = KeychainHelper.loadStr("mibox_certkey") ?? savedIP
        guard KeychainHelper.hasCert(certKey: certKey) else {
            discovery.startScan(); return
        }

        // --- Fix 1: Subnet mask ile doğru network karşılaştırması ---
        guard ipOnCurrentNetwork(savedIP) else {
            // Farklı ağdayız — cache kesinlikle çalışmaz
            discovery.startScan(); return
        }

        // --- Fix 2: Connection lock + parallel ---
        await connectionLock.reset()
        isAutoConnecting = true

        // Scan sessizce arka planda başlasın — device bulunca connectTo çağırır
        // ama lock sayesinde cache zaten bağlandıysa yoksayılır
        discovery.startScanSilent { [connectionLock] device in
            Task { @MainActor in
                guard await connectionLock.tryAcquire() else { return }
                // Scan kazandı — cache connect artık yoksayılacak
                self.isAutoConnecting = false
                self.connectTo(device)
            }
        }

        // Fix 3: 2.5sn timeout — TV sleep/wake için yeterli
        let reachable = await tcpCheck(ip: savedIP, port: 6466, timeout: 2.5)

        guard await connectionLock.tryAcquire() else {
            // Scan zaten bir cihaz bulup lock'u aldı — cache sonucunu yoksay
            isAutoConnecting = false
            return
        }

        // Cache kazandı — scan'i durdur
        discovery.stop()
        let pPort = KeychainHelper.loadInt(KeychainHelper.pairingPortKey(certKey: certKey), def: 6467)
        let rPort = KeychainHelper.loadInt(KeychainHelper.remotePortKey(certKey: certKey),  def: 6466)
        isAutoConnecting = false

        if reachable {
            var device = DiscoveredDevice(ip: savedIP, hasCert: true,
                                          pairingPort: pPort, remotePort: rPort)
            if certKey != savedIP { device.mac = certKey }
            launchRemote(device)
        }
        // reachable değilse: lock alındı ama bağlanamadık.
        // scan stop edildi — kullanıcı "Cihaz bulunamadı" görür, manuel scan yapabilir.
    }

    private func connectManual() {
        guard !manualIP.isEmpty else { return }
        let ip = manualIP.trimmingCharacters(in: .whitespaces)
        KeychainHelper.saveStr(ip, key: "mibox_ip")
        let pPort = KeychainHelper.loadInt(KeychainHelper.pairingPortKey(certKey: ip), def: 6467)
        let rPort = KeychainHelper.loadInt(KeychainHelper.remotePortKey(certKey: ip),  def: 6466)
        let hasCert = KeychainHelper.hasCert(certKey: ip)
        Task {
            var hasApk = false
            if await tcpCheck(ip: ip, port: 9876) { hasApk = true }
            let device = DiscoveredDevice(ip: ip, hasCert: hasCert, hasApk: hasApk,
                                          pairingPort: pPort, remotePort: rPort)
            connectTo(device)
        }
    }

    /// IP + subnet mask ile gerçek network adresi hesaplayarak karşılaştırır.
    /// /23, /22 gibi non-/24 subnet'leri ve VPN senaryolarını doğru yakalar.
    private func ipOnCurrentNetwork(_ ip: String) -> Bool {
        guard let targetAddr = ipToUInt32(ip) else { return false }

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return false }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_LOOPBACK == 0,
                  flags & IFF_UP != 0 else { continue }

            var localAddr: UInt32 = 0
            var mask: UInt32 = 0

            ifa.pointee.ifa_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                localAddr = UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            ifa.pointee.ifa_netmask?.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                mask = UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }

            guard localAddr != 0, mask != 0 else { continue }

            // Aynı network: (localAddr & mask) == (targetAddr & mask)
            if (localAddr & mask) == (targetAddr & mask) { return true }
        }
        return false
    }

    private func ipToUInt32(_ ip: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    private func tcpCheck(ip: String, port: Int, timeout: Double = 2.0) async -> Bool {
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
                try? await Task.sleep(for: .seconds(timeout))
                guard !done else { return }; done = true; conn.cancel(); cont.resume(returning: false)
            }
        }
    }
}

// MARK: - ConnectionLock
// Race condition önlemek için: cache connect ve scan result
// aynı anda destination set etmesin. İlk tryAcquire() true döner, sonrakiler false.
// Swift actor ile isolation garantisi sağlanır — NSLock gerekmez.
actor ConnectionLock {
    private var acquired = false

    func tryAcquire() -> Bool {
        guard !acquired else { return false }
        acquired = true; return true
    }

    func reset() { acquired = false }
}

// MARK: - DeviceCard

struct DeviceCard: View {
    let device: DiscoveredDevice
    let onConnect: () -> Void
    let onRepair:  () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.blueDeep).frame(width: 44, height: 44)
                Image(systemName: "tv")
                    .foregroundColor(device.hasCert ? .greenOk : .redAccent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Mi Box").foregroundColor(.white).fontWeight(.semibold).font(.subheadline)
                Text(device.ip).foregroundColor(.gray).font(.caption)
                HStack(spacing: 6) {
                    Text(device.hasCert ? "✓ Eşleştirildi" : "Eşleştirilmedi")
                        .foregroundColor(device.hasCert ? .greenOk : Color(hex: "fbbf24"))
                        .font(.system(size: 11))
                    apkBadge
                }
            }
            Spacer()
            HStack(spacing: 6) {
                if device.hasCert {
                    Button(action: onRepair) {
                        Image(systemName: "link.badge.minus").foregroundColor(.gray).font(.system(size: 16))
                    }
                }
                Button(action: onConnect) {
                    Text(device.hasCert ? "Bağlan" : "Eşleştir")
                        .font(.system(size: 13)).foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.redAccent).cornerRadius(10)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.cardBg)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(device.hasCert ? Color.greenOk.opacity(0.5) : Color.blueDeep, lineWidth: 1.5))
        )
        .contentShape(Rectangle())
        .onTapGesture { onConnect() }
    }

    private var apkBadge: some View {
        Text(device.hasApk ? "APK ✓" : "APK yok")
            .font(.system(size: 10))
            .foregroundColor(device.hasApk ? .greenOk : .gray)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background((device.hasApk ? Color.greenOk : Color.gray).opacity(0.15))
            .cornerRadius(4)
    }
}
