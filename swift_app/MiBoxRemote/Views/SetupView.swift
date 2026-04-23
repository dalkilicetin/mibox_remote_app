import SwiftUI
import Network

struct SetupView: View {
    @StateObject private var discovery = DeviceDiscovery()
    @State private var destination: NavDest?
    @State private var showManualEntry = false
    @State private var manualIP = ""

    enum NavDest: Identifiable {
        case pairing(DiscoveredDevice)
        case remote(DiscoveredDevice, MiBoxService?)
        var id: String {
            switch self {
            case .pairing(let d): return "pair-\(d.ip)"
            case .remote(let d, _): return "remote-\(d.ip)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    if discovery.isScanning {
                        ProgressView().progressViewStyle(.linear).tint(.redAccent)
                            .padding(.horizontal, 24).padding(.bottom, 8)
                    }
                    deviceList
                    bottomBar
                }
            }
            .navigationDestination(item: $destination) { dest in
                switch dest {
                case .pairing(let d):
                    PairingView(device: d) { success in
                        if success { destination = .remote(d, nil) }
                        else { destination = nil }
                    }
                case .remote(let d, let svc):
                    RemoteView(device: d, apkService: svc)
                }
            }
        }
        .onAppear { discovery.startScan() }
        .onDisappear { discovery.stop() }
        .alert("Manuel IP Gir", isPresented: $showManualEntry) {
            TextField("192.168.x.x", text: $manualIP)
                .keyboardType(.numbersAndPunctuation)
            Button("Bağlan") { connectManual() }
            Button("İptal", role: .cancel) { }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "tv").font(.system(size: 52)).foregroundColor(.redAccent)
            Text("Mi Box Remote").font(.title.bold()).foregroundColor(.white)
            Text(discovery.status).font(.caption).foregroundColor(.gray).multilineTextAlignment(.center)
        }
        .padding(.top, 28).padding(.bottom, 16).padding(.horizontal, 20)
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

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button(action: { discovery.startScan() }) {
                Label(discovery.isScanning ? "Aranıyor..." : "Yeniden Tara",
                      systemImage: "arrow.clockwise")
                    .foregroundColor(.redAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
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
                    .padding(.vertical, 13)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray))
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 20).padding(.top, 8)
    }

    // MARK: - Actions

    private func connectTo(_ device: DiscoveredDevice) {
        if device.hasCert { launchRemote(device) }
        else { destination = .pairing(device) }
    }

    private func repairDevice(_ device: DiscoveredDevice) {
        KeychainHelper.deleteIdentity(label: KeychainHelper.identityLabel(ip: device.ip))
        destination = .pairing(device)
    }

    private func launchRemote(_ device: DiscoveredDevice) {
        KeychainHelper.saveStr(device.ip, key: "mibox_ip")
        Task {
            var svc: MiBoxService? = nil
            if device.hasApk {
                let s = MiBoxService()
                if await s.connect(to: device.ip) { svc = s }
            }
            destination = .remote(device, svc)
        }
    }

    private func connectManual() {
        guard !manualIP.isEmpty else { return }
        let ip = manualIP.trimmingCharacters(in: .whitespaces)
        KeychainHelper.saveStr(ip, key: "mibox_ip")
        let pPort = KeychainHelper.loadInt(KeychainHelper.pairingPortKey(ip: ip), def: 6467)
        let rPort = KeychainHelper.loadInt(KeychainHelper.remotePortKey(ip: ip),  def: 6466)
        let hasCert = KeychainHelper.hasCert(ip: ip)
        Task {
            var hasApk = false
            if await tcpCheck(ip: ip, port: 9876) { hasApk = true }
            let device = DiscoveredDevice(ip: ip, hasCert: hasCert, hasApk: hasApk,
                                          pairingPort: pPort, remotePort: rPort)
            connectTo(device)
        }
    }

    private func tcpCheck(ip: String, port: Int) async -> Bool {
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
                try? await Task.sleep(for: .seconds(2))
                guard !done else { return }; done = true; conn.cancel(); cont.resume(returning: false)
            }
        }
    }
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
