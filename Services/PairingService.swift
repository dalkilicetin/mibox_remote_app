import Foundation
import Network
import Security
import CryptoKit

@MainActor
final class PairingService {
    enum Err: Error {
        case noCert, noServer, connectionFailed(String), timeout, pinMismatch
    }

    private(set) var serverCert: SecCertificate?
    private var connection: NWConnection?
    private var recvBuf = Data()
    private var pending: [CheckedContinuation<Data, Error>] = []
    private var buffered: [Data] = []

    private var keyPair: CertificateHelper.KeyPair?
    private var certificate: SecCertificate?
    var onLog: ((String) -> Void)?
    private func log(_ s: String) { print("[PAIR] \(s)"); onLog?(s) }

    // MARK: - Step 1: prepare

    func prepare() async throws {
        log("RSA 2048 keypair üretiliyor...")
        let kp   = try CertificateHelper.generateRSAKeyPair()
        let cert = try CertificateHelper.createSelfSignedCert(keyPair: kp)
        keyPair = kp; certificate = cert
        log("Sertifika oluşturuldu.")
    }

    // MARK: - Step 2: connect with TLS

    func connect(ip: String, port: Int) async throws {
        guard let cert = certificate, let kp = keyPair else { throw Err.noCert }

        // Temporarily store identity so NWConnection can use it
        let label = "mibox_pairing_temp_\(ip)"
        KeychainHelper.deleteIdentity(label: label)
        KeychainHelper.storeIdentity(cert: cert, privateKey: kp.privateKey, label: label)

        guard let identity = KeychainHelper.loadIdentity(label: label) else {
            KeychainHelper.deleteIdentity(label: label)
            throw Err.connectionFailed("SecIdentity oluşturulamadı")
        }

        let tlsOpts = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tlsOpts.securityProtocolOptions, sec_identity_create(identity)!)
        sec_protocol_options_set_verify_block(tlsOpts.securityProtocolOptions, { [weak self] _, trust, complete in
            let cfTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            if let sc = SecTrustGetCertificateAtIndex(cfTrust, 0) {
                DispatchQueue.main.async { self?.serverCert = sc }
            }
            complete(true)
        }, .global())

        let conn = NWConnection(host: .init(ip), port: .init(rawValue: UInt16(port))!,
                                using: NWParameters(tls: tlsOpts, tcp: .init()))
        connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !done else { return }; done = true
                    Task { @MainActor in self?.startReceive(); cont.resume() }
                case .failed(let e):
                    guard !done else { return }; done = true
                    KeychainHelper.deleteIdentity(label: label)
                    cont.resume(throwing: Err.connectionFailed(e.localizedDescription))
                case .cancelled:
                    guard !done else { return }; done = true
                    cont.resume(throwing: Err.connectionFailed("İptal"))
                default: break
                }
            }
            conn.start(queue: .global())
            Task {
                try? await Task.sleep(for: .seconds(5))
                guard !done else { return }; done = true; conn.cancel()
                KeychainHelper.deleteIdentity(label: label)
                cont.resume(throwing: Err.timeout)
            }
        }
    }

    // MARK: - Step 3: handshake

    func performHandshake() async throws {
        log("→ pairing_request")
        send(buildPairingRequest())
        _ = try await readMsg(timeout: 3); log("← ack")

        send(Data([8,2,16,200,1,162,1,8,10,4,8,3,16,6,24,1]))   // options
        _ = try await readMsg(timeout: 5); log("← options_ack")

        send(Data([8,2,16,200,1,242,1,8,10,4,8,3,16,6,16,1]))   // configuration
        _ = try await readMsg(timeout: 3); log("← config_ack")

        log("Handshake tamamlandı — PIN bekleniyor")
    }

    // MARK: - Step 4: PIN

    func sendPin(_ pin: String) async throws -> Bool {
        guard let serverCert else { log("server cert yok"); return false }
        guard let kp = keyPair else { return false }

        let pinUp = pin.uppercased()
        guard pinUp.count == 6,
              let checkByte = UInt8(pinUp.prefix(2), radix: 16),
              let pinHash = Data(hexString: String(pinUp.dropFirst(2))) else {
            log("Geçersiz PIN formatı"); return false
        }

        guard let sComp = CertificateHelper.rsaComponents(from: serverCert),
              let cComp = CertificateHelper.rsaComponents(from: kp.publicKey) else {
            log("RSA bileşenleri çıkarılamadı"); return false
        }

        var input = Data()
        input.append(cComp.modulus); input.append(cComp.exponent)
        input.append(sComp.modulus); input.append(sComp.exponent)
        input.append(pinHash)

        let secret = Array(SHA256.hash(data: input))
        log("secret[0]=\(String(format:"%02x",secret[0])) check=\(String(format:"%02x",checkByte))")

        guard secret[0] == checkByte else { log("PIN mismatch"); return false }

        var msg = Data([8,2,16,200,1,98,34,10,32])
        msg.append(contentsOf: secret)
        send(msg)
        _ = try await readMsg(timeout: 3)
        log("← secret_ack — EŞLEŞTİRME BAŞARILI!")
        return true
    }

    // MARK: - Persist identity permanently

    func saveIdentity(ip: String) {
        guard let cert = certificate, let kp = keyPair else {
            log("HATA: saveIdentity — cert veya keyPair nil")
            return
        }
        let label = KeychainHelper.identityLabel(ip: ip)
        KeychainHelper.deleteIdentity(label: label)
        let ok = KeychainHelper.storeIdentity(cert: cert, privateKey: kp.privateKey, label: label)
        if ok {
            let verify = KeychainHelper.loadIdentity(label: label)
            log(verify != nil ? "✓ Keychain kaydedildi ve doğrulandı (\(ip))" : "HATA: Kaydedildi ama yüklenemedi (\(ip))")
        } else {
            log("HATA: Keychain'e kayıt başarısız (\(ip))")
        }
    }

    func close() { connection?.cancel(); connection = nil }

    // MARK: - Frame codec (1-byte length prefix)

    private func send(_ payload: Data) {
        guard let conn = connection else { return }
        var frame = Data([UInt8(payload.count)])
        frame.append(payload)
        conn.send(content: frame, completion: .idempotent)
    }

    private func startReceive() { receive() }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { Task { @MainActor in self.processRecv(data) } }
            if err == nil && !done { self.receive() }
        }
    }

    private func processRecv(_ data: Data) {
        recvBuf.append(data)
        while !recvBuf.isEmpty {
            let expected = Int(recvBuf[recvBuf.startIndex])
            guard recvBuf.count >= 1 + expected else { break }
            let msg = recvBuf[1..<(1 + expected)]
            recvBuf.removeSubrange(..<(1 + expected))
            deliver(Data(msg))
        }
    }

    private func deliver(_ msg: Data) {
        if !pending.isEmpty { pending.removeFirst().resume(returning: msg) }
        else { buffered.append(msg) }
    }

    private func readMsg(timeout: Double) async throws -> Data {
        if !buffered.isEmpty { return buffered.removeFirst() }
        return try await withCheckedThrowingContinuation { cont in
            pending.append(cont)
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if let i = self.pending.firstIndex(where: { _ in true }) {
                    self.pending.remove(at: i).resume(throwing: Err.timeout)
                }
            }
        }
    }

    private func buildPairingRequest() -> Data {
        let svc = Data("ATV Remote".utf8)
        let cli = Data("com.mibox.remote".utf8)
        let inner = Data([10, UInt8(svc.count)]) + svc + Data([18, UInt8(cli.count)]) + cli
        return Data([8,2,16,200,1,82,UInt8(inner.count)]) + inner
    }
}

extension Data {
    init?(hexString: String) {
        var hex = hexString
        if hex.count % 2 != 0 { hex = "0" + hex }
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        self = out
    }
}
