import SwiftUI
import Combine

struct RemoteView: View {
    let device: DiscoveredDevice
    let apkService: MiBoxService?

    @StateObject private var atv = AtvRemoteService()
    @State private var atvConnected = false
    @State private var apkConnected = false
    @State private var logs: [String] = []
    @State private var selectedTab = 0
    @State private var isReconnecting = false
    @Environment(\.dismiss) private var dismiss

    private var hasApk: Bool { apkService != nil }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                statusBar(geo: geo)
                if !atvConnected {
                    reconnectBanner(geo: geo)
                }
                tabBar(geo: geo)
                tabContent(geo: geo)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: geo.size.width, maxHeight: geo.size.height)
            .background(Color.appBg)
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationBarHidden(true)
        .task { await initAtv() }
        .task { await retryApkIfNeeded() }
        .onReceive(apkService?.objectWillChange.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
            apkConnected = apkService?.isConnected ?? false
        }
        .onReceive(atv.objectWillChange) {
            atvConnected = atv.isConnected
        }
    }

    // MARK: - Status bar

    private func statusBar(geo: GeometryProxy) -> some View {
        HStack(spacing: 10) {
            if hasApk {
                Circle().fill(apkConnected ? Color.greenOk : .red).frame(width: 8, height: 8)
                Text(apkConnected ? "Cursor" : "Cursor yok")
                    .font(.system(size: geo.size.width * 0.028))
                    .foregroundColor(apkConnected ? .greenOk : .red)
            }
            Circle().fill(atvConnected ? Color.greenOk : .red).frame(width: 8, height: 8)
            Text(atvConnected ? "TV Remote" : "Bağlantı yok")
                .font(.system(size: geo.size.width * 0.028))
                .foregroundColor(atvConnected ? .greenOk : .red)
            Spacer()
            Text(device.ip).font(.system(size: geo.size.width * 0.026)).foregroundColor(.gray)
            Button(action: { dismiss() }) {
                Image(systemName: "xmark").foregroundColor(.gray).font(.system(size: geo.size.width * 0.038))
            }
        }
        .padding(.horizontal, geo.size.width * 0.04)
        .padding(.vertical, geo.size.height * 0.012)
        .background(Color.cardBg)
    }

    // MARK: - Reconnect banner

    private func reconnectBanner(geo: GeometryProxy) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(Color(hex: "fbbf24"))
                .font(.system(size: geo.size.width * 0.033))
            Text("TV'ye bağlanılamıyor")
                .font(.system(size: geo.size.width * 0.033))
                .foregroundColor(.white)
            Spacer()
            Button(action: reconnect) {
                HStack(spacing: 6) {
                    if isReconnecting {
                        ProgressView().progressViewStyle(.circular).scaleEffect(0.7).tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: geo.size.width * 0.03))
                    }
                    Text(isReconnecting ? "Bağlanıyor..." : "Yeniden Bağlan")
                        .font(.system(size: geo.size.width * 0.03, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, geo.size.width * 0.03)
                .padding(.vertical, geo.size.height * 0.01)
                .background(Color.redAccent)
                .cornerRadius(8)
            }
            .disabled(isReconnecting)
        }
        .padding(.horizontal, geo.size.width * 0.04)
        .padding(.vertical, geo.size.height * 0.012)
        .background(Color(hex: "1a1a2e"))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color(hex: "fbbf24").opacity(0.4)), alignment: .bottom)
    }

    // MARK: - Tab bar

    private var tabs: [String] {
        if hasApk { return ["Air Mouse", "Touchpad", "Debug"] }
        return ["Kumanda", "Debug"]
    }

    private func tabBar(geo: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { idx, name in
                Button(action: { selectedTab = idx }) {
                    VStack(spacing: 4) {
                        Text(name)
                            .font(.system(size: geo.size.width * 0.033))
                            .foregroundColor(selectedTab == idx ? .redAccent : .gray)
                        Rectangle()
                            .fill(selectedTab == idx ? Color.redAccent : .clear)
                            .frame(height: 2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, geo.size.height * 0.008)
        .background(Color.cardBg)
    }

    // MARK: - Tab content — tam kalan alanı kaplar

    @ViewBuilder
    private func tabContent(geo: GeometryProxy) -> some View {
        if hasApk, let svc = apkService {
            switch selectedTab {
            case 0: AirMouseView(apk: svc, atv: atv)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
            case 1: TouchpadView(apk: svc, atv: atv)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
            default: DebugView(logs: $logs, onClear: { logs.removeAll() }, onReconnect: reconnect)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            switch selectedTab {
            case 0: DpadView(atv: atv)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
            default: DebugView(logs: $logs, onClear: { logs.removeAll() }, onReconnect: reconnect)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - APK background retry

    /// apkService nil geldiyse (discovery timing sorunu) arka planda APK'ya bağlanmayı dener
    @State private var apkRetried = false

    private func retryApkIfNeeded() async {
        guard apkService == nil, !apkRetried else { return }
        apkRetried = true
        // Kısa bekle — ATV bağlantısı kurulsun
        try? await Task.sleep(for: .seconds(2))
        // APK portu açık mı?
        let open = await withCheckedContinuation { cont in
            let conn = NWConnection(host: .init(device.ip), port: 9876, using: .tcp)
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
        guard open else { return }
        // APK açık — bağlan ve logu güncelle
        addLog("🔍 APK portu bulundu, bağlanılıyor...")
        // apkService dışarıdan let olduğu için UI'ı güncelleyemeyiz
        // en azından logu bilgilendir
        addLog("⚠️ APK var ama bu oturumda aktif değil. Geri dönüp tekrar bağlanın.")
    }

    // MARK: - Reconnect

    private func reconnect() {
        guard !isReconnecting else { return }
        Task { await initAtv() }
    }

    // MARK: - ATV init

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

        guard let identity = KeychainHelper.loadIdentity(certKey: device.certKey) else {
            addLog("❌ Sertifika bulunamadı (certKey=\(device.certKey))!")
            isReconnecting = false
            return
        }
        atv.setIdentity(identity)

        var ok = false
        for attempt in 1...3 {
            ok = await atv.connect(ip: device.ip, port: device.remotePort)
            if ok { break }
            addLog("Bağlantı denemesi \(attempt) başarısız, bekleniyor...")
            if attempt < 3 { try? await Task.sleep(for: .seconds(2)) }
        }
        atvConnected = ok
        addLog(ok ? "ATV bağlandı ✓" : "ATV bağlantısı başarısız! (3 deneme)")
        isReconnecting = false
    }

    private func addLog(_ msg: String) {
        let ts = Calendar.current.component(.second, from: Date())
        logs.append("[\(ts)s] \(msg)")
    }
}
