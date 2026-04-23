import Foundation
import Network
import Security
import CryptoKit

// MARK: - ATV Pairing Protocol Notes
//
// Pairing sequence (port 6467, 1-byte length-prefixed frames):
//
//   Client → TV : PairingRequest      { service_name, client_name }         field 10 (0x52)
//   TV → Client : PairingAck          { status: OK }
//   Client → TV : OptionsRequest      { encoding: HEX(3), length: 6, role: INPUT(1) }  field 20 (0xA2,0x01)
//   TV → Client : OptionsAck
//   Client → TV : ConfigurationRequest { encoding: HEX(3), length: 6, role: INPUT(1) } field 30 (0xF2,0x01)
//   TV → Client : ConfigurationAck    ← TV ekranda PIN gösterir
//
//   [kullanıcı PIN girer: 6 hex char, örn "A3F21C"]
//
//   secret = SHA256(clientMod ‖ clientExp ‖ serverMod ‖ serverExp ‖ pinBytes)
//   pinBytes = last 4 hex chars decoded = 2 bytes (örn "F21C" → [0xF2,0x1C])
//   checkByte = first 2 hex chars decoded = 1 byte (örn "A3" → 0xA3)
//   doğrulama: secret[0] == checkByte (client-side sanity check)
//
//   secret mesajı (field 24, 0xC2,0x02):
//     payload = [8,2,16,200,1,0xC2,0x02,0x22,0x0A,0x20] + secret(32 bytes)  → frame length = 42
//
//   TV → Client : SecretAck → eşleştirme başarılı

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
    private var tempIdentityLabel: String?
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

        let label = "mibox_pairing_temp_\(ip)"
        tempIdentityLabel = label
        guard let identity = KeychainHelper.buildTempIdentity(cert: cert, privateKey: kp.privateKey, label: label) else {
            KeychainHelper.deleteTempIdentity(label: label)
            tempIdentityLabel = nil
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
                    KeychainHelper.deleteTempIdentity(label: label)
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
                KeychainHelper.deleteTempIdentity(label: label)
                cont.resume(throwing: Err.timeout)
            }
        }
    }

    // MARK: - Step 3: handshake

    func performHandshake() async throws {
        log("→ pairing_request")
        send(buildPairingRequest())
        _ = try await readMsg(timeout: 3); log("← pairing_ack")

        send(Data([8,2,16,200,1,162,1,8,10,4,8,3,16,6,24,1]))   // options (field 20)
        _ = try await readMsg(timeout: 5); log("← options_ack")

        send(Data([8,2,16,200,1,242,1,8,10,4,8,3,16,6,16,1]))   // configuration (field 30)
        _ = try await readMsg(timeout: 3); log("← config_ack — TV PIN gösteriyor")

        log("Handshake tamamlandı — PIN bekleniyor")
    }

    // MARK: - Step 4: PIN

    func sendPin(_ pin: String) async throws -> Bool {
        guard let serverCert else { log("server cert yok"); return false }
        guard let kp = keyPair else { return false }

        let pinUp = pin.trimmingCharacters(in: .whitespaces).uppercased()

        // PIN formatı: 6 hex karakter (örn "A3F21C")
        // checkByte  = ilk 2 char decode = 1 byte (örn 0xA3) — client sanity check
        // pinBytes   = son 4 char decode = 2 byte (örn [0xF2, 0x1C]) — hash input
        guard pinUp.count == 6,
              let checkByte = UInt8(pinUp.prefix(2), radix: 16),
              let pinBytes  = Data(hexString: String(pinUp.dropFirst(2))) else {
            log("Geçersiz PIN formatı — 6 hex karakter bekleniyor (örn: A3F21C)")
            return false
        }

        guard let sComp = CertificateHelper.rsaComponents(from: serverCert),
              let cComp = CertificateHelper.rsaComponents(from: kp.publicKey) else {
            log("RSA bileşenleri çıkarılamadı"); return false
        }

        // secret = SHA256(clientMod ‖ clientExp ‖ serverMod ‖ serverExp ‖ pinBytes)
        var hashInput = Data()
        hashInput.append(cComp.modulus)
        hashInput.append(cComp.exponent)
        hashInput.append(sComp.modulus)
        hashInput.append(sComp.exponent)
        hashInput.append(pinBytes)

        let secret = Array(SHA256.hash(data: hashInput))

        log("secret[0]=\(String(format:"%02x", secret[0])) checkByte=\(String(format:"%02x", checkByte))")

        // client-side doğrulama: hash'in ilk byte'ı PIN'in ilk byte'ıyla eşleşmeli
        guard secret[0] == checkByte else {
            log("PIN doğrulanamadı — secret[0] ≠ checkByte. PIN yanlış girilmiş olabilir.")
            return false
        }

        // SecretCredentials mesajı:
        // [8,2,16,200,1] = header (version=2, status=OK)
        // [0xC2,0x02]    = field 24 wire 2 (secret_credentials outer) — NOT: 0x62(98)=field12 YANLIŞ
        // [0x22]         = field 4 wire 2 (credentials inner)
        // [0x0A]         = field 1 wire 2 (secret bytes tag)
        // [0x20]         = 32 (secret length)
        // + 32 bytes secret
        var msg = Data([0x08, 0x02, 0x10, 0xC8, 0x01, 0xC2, 0x02, 0x22, 0x0A, 0x20])
        msg.append(contentsOf: secret)
        send(msg)
        log("→ secret gönderildi (\(msg.count) bytes)")

        _ = try await readMsg(timeout: 3)
        log("← secret_ack — EŞLEŞTİRME BAŞARILI!")
        return true
    }

    // MARK: - Persist identity permanently

    func saveIdentity(ip: String) {
        guard let cert = certificate, let kp = keyPair else {
            log("HATA: saveIdentity — cert veya keyPair nil"); return
        }
        let certDER = SecCertificateCopyData(cert) as Data
        var cfErr: Unmanaged<CFError>?
        guard let keyDER = SecKeyCopyExternalRepresentation(kp.privateKey, &cfErr) as Data? else {
            log("HATA: Private key export başarısız: \(cfErr?.takeRetainedValue() as Any)"); return
        }
        KeychainHelper.deleteCertAndKey(ip: ip)
        KeychainHelper.storeCertAndKey(ip: ip, certDER: certDER, keyDER: keyDER)
        let checkCert = KeychainHelper.hasCert(ip: ip)
        log("KAYIT KONTROL: hasCert=\(checkCert)")
        let verify = KeychainHelper.loadIdentity(label: KeychainHelper.identityLabel(ip: ip))
        log(verify != nil ? "✓ Identity kaydedildi ve doğrulandı (\(ip))" : "HATA: Identity doğrulanamadı (\(ip))")
    }

    func close() {
        connection?.cancel(); connection = nil
        if let label = tempIdentityLabel { KeychainHelper.deleteTempIdentity(label: label); tempIdentityLabel = nil }
    }

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
        // PairingRequest: { service_name: "ATV Remote", client_name: "com.google.android.tv.remote" }
        // field 10 (0x52): service name
        // field 18 (0x12 inside): client name
        let svc = Data("ATV Remote".utf8)
        let cli = Data("com.google.android.tv.remote".utf8)
        let inner = Data([0x0A, UInt8(svc.count)]) + svc + Data([0x12, UInt8(cli.count)]) + cli
        return Data([0x08, 0x02, 0x10, 0xC8, 0x01, 0x52, UInt8(inner.count)]) + inner
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
