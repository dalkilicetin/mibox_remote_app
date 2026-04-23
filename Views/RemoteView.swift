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
        ZStack { Color.appBg.ignoresSafeArea()
            VStack(spacing: 0) {
                statusBar
                if !atvConnected {
                    reconnectBanner
                }
                tabBar
                tabContent
            }
        }
        .navigationBarHidden(true)
        .task { await initAtv() }
        .onReceive(apkService?.objectWillChange.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
            apkConnected = apkService?.isConnected ?? false
        }
        .onReceive(atv.objectWillChange) {
            atvConnected = atv.isConnected
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            if hasApk {
                Circle().fill(apkConnected ? Color.greenOk : .red).frame(width: 8, height: 8)
                Text(apkConnected ? "Cursor" : "Cursor yok")
                    .font(.system(size: 11)).foregroundColor(apkConnected ? .greenOk : .red)
            }
            Circle()
                .fill(atvConnected ? Color.greenOk : .red)
                .frame(width: 8, height: 8)
            Text(atvConnected ? "TV Remote" : "Bağlantı yok")
                .font(.system(size: 11)).foregroundColor(atvConnected ? .greenOk : .red)
            Spacer()
            Text(device.ip).font(.system(size: 11)).foregroundColor(.gray)
            Button(action: { dismiss() }) {
                Image(systemName: "xmark").foregroundColor(.gray).font(.system(size: 14))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.cardBg)
    }

    // MARK: - Reconnect banner (sadece bağlantı yokken görünür)

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
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.7)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
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
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color(hex: "fbbf24").opacity(0.4)), alignment: .bottom)
    }

    // MARK: - Tab bar

    private var tabs: [String] {
        if hasApk { return ["Air Mouse", "Touchpad", "Debug"] }
        return ["Kumanda", "Debug"]
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { idx, name in
                Button(action: { selectedTab = idx }) {
                    VStack(spacing: 4) {
                        Text(name).font(.system(size: 13))
                            .foregroundColor(selectedTab == idx ? .redAccent : .gray)
                        Rectangle().fill(selectedTab == idx ? Color.redAccent : .clear).frame(height: 2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 4)
        .background(Color.cardBg)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        if hasApk, let svc = apkService {
            switch selectedTab {
            case 0: AirMouseView(apk: svc, atv: atv)
            case 1: TouchpadView(apk: svc, atv: atv)
            default: DebugView(logs: $logs, onClear: { logs.removeAll() }, onReconnect: reconnect)
            }
        } else {
            switch selectedTab {
            case 0: DpadView(atv: atv)
            default: DebugView(logs: $logs, onClear: { logs.removeAll() }, onReconnect: reconnect)
            }
        }
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
