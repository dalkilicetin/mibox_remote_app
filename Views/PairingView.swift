import SwiftUI

struct PairingView: View {
    let device: DiscoveredDevice
    let onDone: (Bool) -> Void

    @StateObject private var vm = PairingVM()

    var body: some View {
        ZStack { Color.appBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "link").font(.system(size: 56)).foregroundColor(.redAccent)

                    Text(vm.status).font(.body).foregroundColor(.white).multilineTextAlignment(.center)

                    if vm.waitingPin {
                        pinSection
                    } else if !vm.status.contains("Hata") && !vm.status.contains("kurulamadı") {
                        ProgressView().tint(.redAccent)
                    }

                    if !vm.logs.isEmpty { logBox }
                }
                .padding(24)
            }
        }
        .navigationTitle("TV Eşleştirme — \(device.ip)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await vm.start(device: device) }
        .onReceive(vm.$pairingSuccess) { success in
            if success { onDone(true) }
        }
    }

    // MARK: - PIN section

    private var pinSection: some View {
        VStack(spacing: 16) {
            TextField("XXXXXX", text: $vm.pin)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .tracking(8)
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
                .padding()
                .background(Color.blueDeep)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.redAccent))
                .textCase(.uppercase)
                .autocorrectionDisabled()
                .onSubmit { Task { await vm.submitPin() } }

            Button(action: { Task { await vm.submitPin() } }) {
                Group {
                    if vm.verifying {
                        ProgressView().tint(.white)
                    } else {
                        Text("Onayla").font(.headline).foregroundColor(.white)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(Color.redAccent).cornerRadius(12)
            }
            .disabled(vm.verifying)
        }
    }

    private var logBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("DEBUG LOG").font(.system(size: 10, weight: .bold)).foregroundColor(.greenOk)
                Spacer()
                Button("Temizle") { vm.logs.removeAll() }.font(.system(size: 9)).foregroundColor(.gray)
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(vm.logs.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(logColor(line))
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
                .frame(height: 200)
                .onChange(of: vm.logs.count) { _ in
                    proxy.scrollTo(vm.logs.count - 1, anchor: .bottom)
                }
            }
        }
        .background(Color.terminalBg)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blueDeep))
        .cornerRadius(8)
    }

    private func logColor(_ line: String) -> Color {
        if line.contains("HATA") || line.contains("hata") || line.contains("mismatch") { return .red }
        if line.contains("OK") || line.contains("BAŞARILI") || line.contains("ack") { return .greenOk }
        return .gray
    }
}

// MARK: - ViewModel

@MainActor
final class PairingVM: ObservableObject {
    @Published var status = "Başlatılıyor..."
    @Published var waitingPin = false
    @Published var verifying  = false
    @Published var pin = ""
    @Published var logs: [String] = []
    @Published var pairingSuccess = false

    private let svc = PairingService()
    private var deviceIP = ""
    private var certKey  = ""  // MAC varsa MAC, yoksa IP

    func start(device: DiscoveredDevice) async {
        self.deviceIP = device.ip
        self.certKey  = device.certKey
        svc.onLog = { [weak self] msg in Task { @MainActor in self?.addLog(msg) } }
        do {
            status = "Sertifika oluşturuluyor..."
            try await svc.prepare()

            let ports = uniquePorts([device.pairingPort, 6467, 6468, 7676])
            var connected = false
            for port in ports {
                status = "Bağlanılıyor... (port \(port))"
                addLog("Port \(port) deneniyor...")
                do {
                    try await svc.connect(ip: device.ip, port: port)
                    try await svc.performHandshake()
                    KeychainHelper.saveInt(port, key: KeychainHelper.pairingPortKey(certKey: device.certKey))
                    connected = true
                    // Bağlantı başarılı - serverCert'ten MAC al, certKey'i güncelle
                    if let mac = svc.serverMac {
                        self.certKey = mac
                        addLog("📱 TV MAC: \(mac) → certKey güncellendi")
                        // Eski IP bazlı kayıt varsa MAC'e migrate et
                        KeychainHelper.migrateLegacyKeys(fromIP: device.ip, toMac: mac)
                    } else {
                        addLog("⚠️ TV MAC parse edilemedi, IP kullanılıyor: \(device.ip)")
                    }
                    break
                } catch {
                    addLog("Port \(port) hata: \(error.localizedDescription)")
                    svc.close()
                }
            }
            if connected {
                status = "TV ekranındaki 6 haneli kodu girin:"
                waitingPin = true
            } else {
                status = "Bağlantı kurulamadı!"
            }
        } catch {
            status = "Hata: \(error.localizedDescription)"
        }
    }

    func submitPin() async {
        let p = pin.trimmingCharacters(in: .whitespaces).uppercased()
        guard p.count >= 6 else { return }
        verifying = true; status = "Doğrulanıyor..."
        do {
            let ok = try await svc.sendPin(p)
            if ok {
                svc.saveIdentity(certKey: certKey)
                KeychainHelper.saveInt(6466, key: KeychainHelper.remotePortKey(certKey: certKey))
                status = "Eşleştirme başarılı!"
                // TV'nin pairing bağlantısını kapatıp remote port'u açmasına zaman ver
                try? await Task.sleep(for: .milliseconds(1500))
                svc.close()
                pairingSuccess = true
            } else {
                status = "Yanlış kod! Tekrar deneyin:"; pin = ""
            }
        } catch {
            status = "Hata: \(error.localizedDescription)"; pin = ""
        }
        verifying = false
    }

    private func addLog(_ msg: String) {
        let ts = Calendar.current.component(.second, from: Date())
        logs.append("[\(ts)s] \(msg)")
        if logs.count > 200 { logs.removeFirst() }
    }

    private func uniquePorts(_ ports: [Int]) -> [Int] {
        var seen = Set<Int>(); var result: [Int] = []
        for p in ports { if seen.insert(p).inserted { result.append(p) } }
        return result
    }
}
