import Foundation
import Network
import Security
import CryptoKit

// MARK: - ATV Pairing Protocol (polo.proto field mapping)
//
// OuterMessage fields (pairing proto):
//   field 10 (0x52) PairingRequest     { service_name(1), client_name(2) }
//   field 11 (0x5A) PairingRequestAck
//   field 20 (0xA2,0x01) Options       { input_encodings(1), preferred_role(3) }
//   field 30 (0xF2,0x01) Configuration { encoding(1), client_role(2) }
//   field 31 (0xFA,0x01) ConfigurationAck
//   field 40 (0xC2,0x02) Secret        { secret(1): 32 bytes }
//   field 41 (0xCA,0x02) SecretAck     { secret(1): 32 bytes }
//
// OuterMessage header: protocol_version(1)=2, status(2)=200
//   → bytes: [0x08,0x02, 0x10,0xC8,0x01]
//
// Secret computation:
//   secret = SHA256(clientMod ‖ clientExp ‖ serverMod ‖ serverExp ‖ pinBytes)
//   PIN = 6 hex chars e.g. "A3F21C"
//   checkByte = first 2 chars decoded = 0xA3  (client sanity check: secret[0] == checkByte)
//   pinBytes  = last  4 chars decoded = [0xF2, 0x1C]  (2 bytes, hash input)
//
// Frame codec: 1-byte length prefix

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
        log("🔑 RSA 2048 keypair üretiliyor...")
        let kp   = try CertificateHelper.generateRSAKeyPair()
        let cert = try CertificateHelper.createSelfSignedCert(keyPair: kp)
        keyPair = kp; certificate = cert
        log("✅ Sertifika oluşturuldu")
    }

    // MARK: - Step 2: connect with TLS

    func connect(ip: String, port: Int) async throws {
        guard let cert = certificate, let kp = keyPair else { throw Err.noCert }

        log("🔌 Pairing TLS bağlantısı → \(ip):\(port)")
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
            if let chain = SecTrustCopyCertificateChain(cfTrust) as? [SecCertificate], let sc = chain.first {
                DispatchQueue.main.async {
                    self?.serverCert = sc
                    self?.log("📜 Server sertifikası alındı")
                }
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
                case .preparing:
                    Task { @MainActor in self?.log("🔄 Pairing TLS hazırlanıyor...") }
                case .ready:
                    guard !done else { return }; done = true
                    Task { @MainActor in self?.startReceive(); cont.resume() }
                case .failed(let e):
                    guard !done else { return }; done = true
                    Task { @MainActor in self?.log("❌ Pairing bağlantı hatası: \(e.localizedDescription)") }
                    KeychainHelper.deleteTempIdentity(label: label)
                    cont.resume(throwing: Err.connectionFailed(e.localizedDescription))
                case .cancelled:
                    guard !done else { return }; done = true
                    cont.resume(throwing: Err.connectionFailed("İptal"))
                case .waiting(let e):
                    Task { @MainActor in self?.log("⏳ Pairing bekleniyor: \(e.localizedDescription)") }
                default: break
                }
            }
            conn.start(queue: .global())
            Task {
                try? await Task.sleep(for: .seconds(5))
                guard !done else { return }; done = true
                Task { @MainActor [self] in self.log("⏰ Pairing bağlantısı zaman aşımı") }
                conn.cancel()
                KeychainHelper.deleteTempIdentity(label: label)
                cont.resume(throwing: Err.timeout)
            }
        }
        log("✅ Pairing TLS bağlandı")
    }

    // MARK: - Step 3: handshake

    func performHandshake() async throws {
        let req = buildPairingRequest()
        log("📤 PairingRequest → (\(req.count)b): \(req.map{String(format:"%02x",$0)}.joined(separator:" "))")
        send(req)
        let ack1 = try await readMsg(timeout: 3)
        log("📥 PairingRequestAck ← (\(ack1.count)b): \(ack1.prefix(8).map{String(format:"%02x",$0)}.joined(separator:" "))")

        // Options: field 20 (0xA2,0x01), encoding=HEX(3), symbolLength=6, role=INPUT(1)
        let opts = Data([0x08,0x02, 0x10,0xC8,0x01, 0xA2,0x01,0x08, 0x0A,0x04,0x08,0x03,0x10,0x06, 0x18,0x01])
        log("📤 Options → (\(opts.count)b): \(opts.map{String(format:"%02x",$0)}.joined(separator:" "))")
        send(opts)
        let ack2 = try await readMsg(timeout: 5)
        log("📥 OptionsAck ← (\(ack2.count)b): \(ack2.prefix(8).map{String(format:"%02x",$0)}.joined(separator:" "))")

        // Configuration: field 30 (0xF2,0x01), encoding=HEX(3), symbolLength=6, clientRole=INPUT(1)
        let cfg = Data([0x08,0x02, 0x10,0xC8,0x01, 0xF2,0x01,0x08, 0x0A,0x04,0x08,0x03,0x10,0x06, 0x10,0x01])
        log("📤 Configuration → (\(cfg.count)b): \(cfg.map{String(format:"%02x",$0)}.joined(separator:" "))")
        send(cfg)
        let ack3 = try await readMsg(timeout: 3)
        log("📥 ConfigurationAck ← (\(ack3.count)b): \(ack3.prefix(8).map{String(format:"%02x",$0)}.joined(separator:" "))")

        log("✅ Handshake tamamlandı — TV'de PIN gösteriliyor")
    }

    // MARK: - Step 4: PIN

    func sendPin(_ pin: String) async throws -> Bool {
        guard let serverCert else { log("❌ server cert yok"); return false }
        guard let kp = keyPair else { log("❌ keyPair yok"); return false }

        let pinUp = pin.trimmingCharacters(in: .whitespaces).uppercased()
        log("🔢 PIN işleniyor: '\(pinUp)'")

        // PIN formatı: 6 hex karakter (örn "A3F21C")
        // checkByte = ilk 2 char = 0xA3 (sanity check)
        // pinBytes  = son 4 char = [0xF2, 0x1C] (hash input)
        guard pinUp.count == 6,
              let checkByte = UInt8(pinUp.prefix(2), radix: 16),
              let pinBytes  = Data(hexString: String(pinUp.dropFirst(2))) else {
            log("❌ Geçersiz PIN formatı — 6 hex karakter gerekli (örn: A3F21C)")
            return false
        }
        log("🔢 checkByte=\(String(format:"%02x",checkByte)) pinBytes=\(pinBytes.map{String(format:"%02x",$0)}.joined())")

        guard let sComp = CertificateHelper.rsaComponents(from: serverCert) else {
            log("❌ Server RSA bileşenleri çıkarılamadı"); return false
        }
        guard let cComp = CertificateHelper.rsaComponents(from: kp.publicKey) else {
            log("❌ Client RSA bileşenleri çıkarılamadı"); return false
        }

        log("🔢 clientMod(\(cComp.modulus.count)b) clientExp(\(cComp.exponent.count)b)")
        log("🔢 serverMod(\(sComp.modulus.count)b) serverExp(\(sComp.exponent.count)b)")

        // secret = SHA256(clientMod ‖ clientExp ‖ serverMod ‖ serverExp ‖ pinBytes)
        var hashInput = Data()
        hashInput.append(cComp.modulus)
        hashInput.append(cComp.exponent)
        hashInput.append(sComp.modulus)
        hashInput.append(sComp.exponent)
        hashInput.append(pinBytes)
        let secret = Array(SHA256.hash(data: hashInput))

        log("🔢 hashInput(\(hashInput.count)b), secret[0]=\(String(format:"%02x",secret[0])) checkByte=\(String(format:"%02x",checkByte))")

        guard secret[0] == checkByte else {
            log("❌ PIN doğrulanamadı — secret[0]=\(String(format:"%02x",secret[0])) ≠ checkByte=\(String(format:"%02x",checkByte))")
            log("ℹ️ TV'deki 6 karakter hex kodu tam olarak girildi mi?")
            return false
        }
        log("✅ Client-side PIN doğrulandı")

        // Secret mesajı: OuterMessage { header, field 40 Secret { secret(1): 32bytes } }
        // field 40 = 0xC2,0x02 (2-byte varint tag)
        var msg = Data([0x08,0x02, 0x10,0xC8,0x01, 0xC2,0x02, 0x22, 0x0A, 0x20])
        msg.append(contentsOf: secret)
        log("📤 Secret → (\(msg.count)b): \(msg.prefix(10).map{String(format:"%02x",$0)}.joined(separator:" ")) ...")
        send(msg)

        let ack = try await readMsg(timeout: 3)
        log("📥 SecretAck ← (\(ack.count)b): \(ack.prefix(8).map{String(format:"%02x",$0)}.joined(separator:" "))")
        log("✅ EŞLEŞTİRME BAŞARILI!")
        return true
    }

    // MARK: - Persist identity

    func saveIdentity(ip: String) {
        guard let cert = certificate, let kp = keyPair else {
            log("❌ saveIdentity — cert veya keyPair nil"); return
        }
        let certDER = SecCertificateCopyData(cert) as Data
        var cfErr: Unmanaged<CFError>?
        guard let keyDER = SecKeyCopyExternalRepresentation(kp.privateKey, &cfErr) as Data? else {
            log("❌ Private key export başarısız: \(cfErr?.takeRetainedValue() as Any)"); return
        }
        log("💾 Keychain'e kaydediliyor (ip=\(ip), cert=\(certDER.count)b, key=\(keyDER.count)b)")
        KeychainHelper.deleteCertAndKey(ip: ip)
        KeychainHelper.storeCertAndKey(ip: ip, certDER: certDER, keyDER: keyDER)
        let hasCert = KeychainHelper.hasCert(ip: ip)
        log("💾 hasCert kontrol: \(hasCert)")
        let verify = KeychainHelper.loadIdentity(label: KeychainHelper.identityLabel(ip: ip))
        log(verify != nil ? "✅ Identity kaydedildi ve doğrulandı (\(ip))" : "❌ Identity doğrulanamadı (\(ip))")
    }

    func close() {
        log("🔌 Pairing bağlantısı kapatılıyor")
        connection?.cancel(); connection = nil
        if let label = tempIdentityLabel {
            KeychainHelper.deleteTempIdentity(label: label)
            tempIdentityLabel = nil
        }
    }

    // MARK: - Frame codec (1-byte length prefix)

    private func send(_ payload: Data) {
        guard let conn = connection else { log("❌ send: bağlantı yok"); return }
        var frame = Data([UInt8(payload.count)])
        frame.append(payload)
        conn.send(content: frame, completion: .idempotent)
    }

    private func startReceive() { receive() }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { Task { @MainActor in self.processRecv(data) } }
            if err == nil && !done { Task { @MainActor in self.receive() } }
            else if let err { Task { @MainActor in self.log("📡 Receive hata: \(err)") } }
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
                    self.log("⏰ readMsg timeout (\(timeout)s)")
                    self.pending.remove(at: i).resume(throwing: Err.timeout)
                }
            }
        }
    }

    // OuterMessage header: [0x08,0x02, 0x10,0xC8,0x01] = version=2, status=OK(200)
    // PairingRequest: field 10 (0x52) { service_name(1)="ATV Remote", client_name(2)="..." }
    private func buildPairingRequest() -> Data {
        let svc = Data("ATV Remote".utf8)
        let cli = Data("com.google.android.tv.remote".utf8)
        let inner = Data([0x0A, UInt8(svc.count)]) + svc + Data([0x12, UInt8(cli.count)]) + cli
        return Data([0x08,0x02, 0x10,0xC8,0x01, 0x52, UInt8(inner.count)]) + inner
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
