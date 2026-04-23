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
    @Environment(\.dismiss) private var dismiss

    private var hasApk: Bool { apkService != nil }

    var body: some View {
        ZStack { Color.appBg.ignoresSafeArea()
            VStack(spacing: 0) {
                statusBar
                tabBar
                tabContent
            }
        }
        .navigationBarHidden(true)
        .task { await initAtv() }
        .onReceive(apkService?.objectWillChange.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
            apkConnected = apkService?.isConnected ?? false
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
            Image(systemName: "tv").font(.system(size: 11))
                .foregroundColor(atvConnected ? .greenOk : .gray)
            Text(atvConnected ? "TV Remote" : "TV bağlantısı yok")
                .font(.system(size: 11)).foregroundColor(atvConnected ? .greenOk : .gray)
            Spacer()
            Text(device.ip).font(.system(size: 11)).foregroundColor(.gray)
            Button(action: { dismiss() }) {
                Image(systemName: "gearshape").foregroundColor(.gray).font(.system(size: 16))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color.cardBg)
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
            default: DebugView(logs: $logs, onClear: { logs.removeAll() }, onReconnect: { Task { await initAtv() } })
            }
        } else {
            switch selectedTab {
            case 0: DpadView(atv: atv)
            default: DebugView(logs: $logs, onClear: { logs.removeAll() }, onReconnect: { Task { await initAtv() } })
            }
        }
    }

    // MARK: - ATV init

    private func initAtv() async {
        atv.onLog = { [weak atv] msg in
            Task { @MainActor in
                let ts = Calendar.current.component(.second, from: Date())
                var logs = logs
                logs.append("[\(ts)s] \(msg)")
                if logs.count > 200 { logs.removeFirst() }
            }
        }
        atv.onLog = { msg in
            Task { @MainActor in
                let ts = Calendar.current.component(.second, from: Date())
                self.logs.append("[\(ts)s] \(msg)")
                if self.logs.count > 200 { self.logs.removeFirst() }
            }
        }

        guard let identity = KeychainHelper.loadIdentity(label: KeychainHelper.identityLabel(ip: device.ip)) else {
            addLog("HATA: Sertifika bulunamadı!")
            return
        }
        atv.setIdentity(identity)
        let ok = await atv.connect(ip: device.ip, port: device.remotePort)
        atvConnected = ok
        addLog(ok ? "ATV bağlandı ✓" : "ATV bağlantısı başarısız!")
    }

    private func addLog(_ msg: String) {
        let ts = Calendar.current.component(.second, from: Date())
        logs.append("[\(ts)s] \(msg)")
    }
}
