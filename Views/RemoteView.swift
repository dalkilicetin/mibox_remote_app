import SwiftUI
import Combine
import Network

struct RemoteView: View {
    // @State: pairing sonrası certKey (MAC) güncellenebilmeli
    @State private var device: DiscoveredDevice
    let apkService: MiBoxService?

    init(device: DiscoveredDevice, apkService: MiBoxService?) {
        _device = State(initialValue: device)
        self.apkService = apkService
    }

    @StateObject private var atv = AtvRemoteService()
    @StateObject private var apk = MiBoxService()

    @State private var logs: [String] = []
    @State private var selectedTab = 0
    @State private var isReconnecting = false
    @State private var showPairing = false
    @State private var isPairingInProgress = false
    @Environment(\.dismiss) private var dismiss

    private var atvConnected: Bool { atv.isConnected }
    private var apkConnected: Bool { apk.isConnected }
    private var hasApk: Bool { apk.isConnected }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            if !atvConnected { reconnectBanner }
            tabBar
            tabContent
        }
        .background(Color.appBg)
        .ignoresSafeArea(edges: .bottom)
        .navigationBarHidden(true)
        .task { await initAtv() }
        .task { startApkContinuous() }
        .onDisappear { apk.disconnect() }
        // Cert invalid → pairing sheet otomatik açılır
        .sheet(isPresented: $showPairing) {
            NavigationStack {
                PairingView(device: device) { success, newCertKey in
                    showPairing = false
                    isPairingInProgress = false
                    atv.setPairing(false)
                    if success {
                        // Risk 1 fix: certKey'i device'a uygula
                        // Böylece initAtv() doğru key ile loadIdentity yapabilir
                        if let key = newCertKey, !key.isEmpty {
                            // MAC ise device.mac set et, değilse IP kalır
                            if key != device.ip {
                                device.mac = key
                            }
                            // UserDefaults'a yeni certkey kaydet
                            KeychainHelper.saveStr(key, key: "mibox_certkey")
                        }
                        Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            await initAtv()
                        }
                    }
                }
            }
        }
    }

    // MARK: - APK connect
    // APK önce UDP discovery broadcast'i bekliyor olabilir.
    // Strateji: önce UDP discovery dene → IP eşleşirse TCP bağlan.
    // UDP başarısız olursa direkt TCP dene (bazı APK versiyonları her zaman TCP dinler).

    private func startApkContinuous() {
        Task {
            while !Task.isCancelled {
                if !apk.isConnected {
                    await tryApkConnect()
                }
                try? await Task.sleep(nanoseconds: apk.isConnected ? 5_000_000_000 : 4_000_000_000)
            }
        }
    }

    private func tryApkConnect() async {
        addLog("🔍 APK aranıyor (UDP broadcast + TCP)...")

        // Önce UDP discovery — APK'nın bize cevap vermesini bekle
        let udpIPs = await MiBoxService.discoverAPK(timeout: 2.0)
        addLog("📡 UDP discovery: \(udpIPs.isEmpty ? "cevap yok" : udpIPs.joined(separator:", "))")

        // Hedef IP'yi bulduk mu?
        let targetIP = device.ip
        let foundViaUDP = udpIPs.contains(targetIP)

        if foundViaUDP {
            addLog("✅ APK UDP'de bulundu (\(targetIP)) → TCP bağlanılıyor")
        } else {
            addLog("⚠️ APK UDP'de bulunamadı → direkt TCP deneniyor")
        }

        // Her iki durumda da TCP bağlantısını dene
        let ok = await apk.connect(to: targetIP)
        addLog(ok ? "✅ APK bağlandı (\(targetIP))" : "❌ APK TCP bağlantısı başarısız")
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            // APK durumu
            Circle()
                .fill(apkConnected ? Color.greenOk : Color(hex: "4A5568"))
                .frame(width: 7, height: 7)
            Text(apkConnected ? "APK ✓" : "APK yok")
                .font(.system(size: 10))
                .foregroundColor(apkConnected ? .greenOk : Color(hex: "4A5568"))

            // ATV durumu
            Circle()
                .fill(atvConnected ? Color.greenOk : .red)
                .frame(width: 7, height: 7)
            Text(atvConnected ? "TV Remote ✓" : "Bağlantı yok")
                .font(.system(size: 10))
                .foregroundColor(atvConnected ? .greenOk : .red)

            Spacer()
            Text(device.ip).font(.system(size: 10)).foregroundColor(Color(hex: "4A5568"))
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .foregroundColor(Color(hex: "4A5568"))
                    .font(.system(size: 13))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.cardBg)
    }

    // MARK: - Reconnect banner (sadece ATV bağlı değilken)

    private var reconnectBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(Color(hex: "fbbf24"))
                .font(.system(size: 13))
            Text("TV'ye bağlanılamıyor")
                .font(.system(size: 13))
                .foregroundColor(.white)
            Spacer()
            Button(action: reconnect) {
                HStack(spacing: 6) {
                    if isReconnecting {
                        ProgressView().progressViewStyle(.circular).scaleEffect(0.7).tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12))
                    }
                    Text(isReconnecting ? "Bağlanıyor..." : "Yeniden Bağlan")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.redAccent)
                .cornerRadius(8)
            }
            .disabled(isReconnecting)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(hex: "1a1a2e"))
        .overlay(
            Rectangle().frame(height: 1)
                .foregroundColor(Color(hex: "fbbf24").opacity(0.4)),
            alignment: .bottom
        )
    }

    // MARK: - Tab bar — APK bağlıysa Air Mouse + Touchpad, değilse sadece Kumanda

    private var tabs: [String] {
        hasApk ? ["Air Mouse", "Touchpad", "Debug"] : ["Kumanda", "Debug"]
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { idx, name in
                Button(action: { selectedTab = min(idx, tabs.count - 1) }) {
                    VStack(spacing: 4) {
                        Text(name)
                            .font(.system(size: 13))
                            .foregroundColor(selectedTab == idx ? .redAccent : .gray)
                        Rectangle()
                            .fill(selectedTab == idx ? Color.redAccent : .clear)
                            .frame(height: 2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 4)
        .background(Color.cardBg)
        // APK bağlandığında tab sayısı değişirse selectedTab'ı sıfırla
        .onChange(of: hasApk) { _ in selectedTab = 0 }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        if hasApk {
            switch selectedTab {
            case 0: AirMouseView(apk: apk, atv: atv)
            case 1: TouchpadView(apk: apk, atv: atv)
            default: debugView
            }
        } else {
            switch selectedTab {
            case 0: DpadView(atv: atv)
            default: debugView
            }
        }
    }

    private var debugView: some View {
        DebugView(
            logs: $logs,
            onClear: { logs.removeAll() },
            onReconnect: reconnect
        )
    }

    // MARK: - ATV reconnect

    private func reconnect() {
        guard !isReconnecting else { return }
        Task { await initAtv() }
    }

    private func initAtv() async {
        guard !isReconnecting else { return }
        isReconnecting = true
        atv.disconnectPermanent()

        atv.onLog = { msg in
            Task { @MainActor in
                let ts = Calendar.current.component(.second, from: Date())
                self.logs.append("[\(ts)s] \(msg)")
                if self.logs.count > 200 { self.logs.removeFirst() }
            }
        }

        // Cert invalid gelince: eski cert'i sil, pairing sheet aç
        atv.onCertInvalid = {
            Task { @MainActor in
                // Fix 3: pairing lock — zaten açıksa ignore et
                guard !self.isPairingInProgress else {
                    self.addLog("ℹ️ Pairing zaten açık, ikinci tetiklenme yoksayıldı")
                    return
                }
                self.addLog("🔐 Cert geçersiz — eski sertifika siliniyor, yeniden eşleştirme başlıyor")
                KeychainHelper.deleteCertAndKey(certKey: self.device.certKey)
                self.isReconnecting = false
                self.isPairingInProgress = true
                self.atv.setPairing(true)   // Fix 4: pairing sırasında reconnect blokla
                self.showPairing = true
            }
        }

        guard let identity = KeychainHelper.loadIdentity(certKey: device.certKey) else {
            addLog("❌ Sertifika bulunamadı — yeniden eşleştirme gerekiyor")
            isReconnecting = false
            showPairing = true
            return
        }
        atv.setIdentity(identity)

        var ok = false
        for attempt in 1...3 {
            ok = await atv.connect(ip: device.ip, port: device.remotePort)
            if ok { break }
            // Cert hatası onCertInvalid'ı tetikledi — döngüyü kes
            if showPairing { isReconnecting = false; return }
            addLog("Bağlantı denemesi \(attempt) başarısız, bekleniyor...")
            if attempt < 3 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        addLog(ok ? "ATV bağlandı ✓" : "ATV bağlantısı başarısız! (3 deneme)")
        isReconnecting = false
    }

    private func addLog(_ msg: String) {
        let ts = Calendar.current.component(.second, from: Date())
        logs.append("[\(ts)s] \(msg)")
    }
}
