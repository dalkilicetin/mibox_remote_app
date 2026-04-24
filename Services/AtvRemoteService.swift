import Foundation
import Network
import Security

// MARK: - ATV Remote v2 Protocol (remotemessage.proto field mapping)
//
// RemoteMessage field → wire type 2 (length-delimited) tag bytes:
//   field  1  remote_configure     → 0x0A
//   field  2  remote_set_active    → 0x12   ← NOT: 0x1A remote_ERROR'dur!
//   field  3  remote_error         → 0x1A
//   field  8  remote_ping_request  → 0x42
//   field  9  remote_ping_response → 0x4A
//   field 10  remote_key_inject    → 0x52
//   field 40  remote_start         → 0xC2, 0x02  (2-byte varint tag)
//   field 50  remote_set_volume    → 0x92, 0x03
//
// Handshake sırası (referans: androidtvremote2/remote.py):
//   TV  → Client : remote_configure { code1: 623, device_info }   [0x0A]
//   Client → TV  : remote_configure { code1: 611, device_info }
//   TV  → Client : remote_set_active { }                           [0x12]
//   Client → TV  : remote_set_active { active: 611 }
//   TV  → Client : remote_start { started: true }                  [0xC2,0x02]
//   [komutlar gönderilebilir]
//
// Ping/Pong:
//   TV  → Client : remote_ping_request  { val1: N }    [0x42]
//   Client → TV  : remote_ping_response { val1: N }    [0x4A]
//
// Key:
//   Client → TV  : remote_key_inject { key_code: N, direction: D }  [0x52]
//   direction: 1=START_LONG, 2=END_LONG, 3=SHORT

@MainActor
final class AtvRemoteService: ObservableObject {
    @Published var isConnected = false
    var onLog: ((String) -> Void)?
    var onCertInvalid: (() -> Void)?

    private var connection: NWConnection?
    private var recvBuf = Data()
    private var configured = false
    private var activeFeatures = 611
    private var pingTask: Task<Void, Never>?
    private var pingTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var ip = ""
    private var port = 6466
    private var identity: SecIdentity?
    private var lastPingTime = Date()
    private var receivedAnyData = false
    private var certErrorFired = false
    // Fix 2: her connection'a benzersiz ID — eski async callback'leri geçersiz kılar
    private var sessionId = UUID()
    // Fix 4: pairing açıkken reconnect başlatma
    private var isPairing = false

    func setIdentity(_ id: SecIdentity) { identity = id }

    /// Pairing başladığında RemoteView çağırır — reconnect bloklanır
    func setPairing(_ active: Bool) {
        isPairing = active
        if active { reconnectTask?.cancel(); reconnectTask = nil }
    }

    // MARK: - Connect

    func connect(ip: String, port: Int = 6466) async -> Bool {
        self.ip = ip; self.port = port
        certErrorFired = false
        receivedAnyData = false
        // Fix 2: yeni session — önceki async callback'ler bu ID'yi eşleştiremez → ignore
        let currentSession = UUID()
        sessionId = currentSession
        cancelInternal()
        guard let identity else { log("❌ Sertifika yok"); return false }

        log("🔌 Bağlanıyor → \(ip):\(port)")
        let tlsOpts = makeTLS(identity: identity)
        let params  = NWParameters(tls: tlsOpts, tcp: .init())
        let conn    = NWConnection(host: .init(ip), port: .init(rawValue: UInt16(port))!, using: params)
        connection  = conn

        return await withCheckedContinuation { cont in
            var done = false
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .preparing:
                    Task { @MainActor in self?.log("🔄 TLS hazırlanıyor...") }
                case .ready:
                    guard !done else { return }; done = true
                    Task { @MainActor in
                        // Fix 2: session kontrolü
                        guard self?.sessionId == currentSession else {
                            self?.log("⚠️ Eski session ready, ignore")
                            conn.cancel(); return
                        }
                        self?.isConnected = true
                        self?.startReceive()
                        self?.scheduleFallbackConfigure()
                        self?.log("✅ TCP+TLS bağlandı: \(ip):\(port)")
                        cont.resume(returning: true)
                    }
                case .failed(let e):
                    guard !done else { return }; done = true
                    Task { @MainActor in
                        guard self?.sessionId == currentSession else { return }
                        self?.log("❌ Bağlantı hatası: \(e.localizedDescription)")
                        if self?.isCertError(e.localizedDescription) == true {
                            self?.onCertError(e.localizedDescription)
                        } else {
                            self?.onDisconnect()
                        }
                    }
                    cont.resume(returning: false)
                case .cancelled:
                    guard !done else { return }; done = true
                    Task { @MainActor in self?.log("🚫 Bağlantı iptal edildi") }
                    cont.resume(returning: false)
                case .waiting(let e):
                    Task { @MainActor in self?.log("⏳ Bekleniyor: \(e.localizedDescription)") }
                default: break
                }
            }
            conn.start(queue: .global())
            // 8sn timeout
            Task {
                try? await Task.sleep(for: .seconds(8))
                guard !done else { return }; done = true
                Task { @MainActor [self] in
                    guard self.sessionId == currentSession else { return }
                    self.log("⏰ Bağlantı zaman aşımı (8s)")
                }
                conn.cancel(); cont.resume(returning: false)
            }
        }
    }

    func sendKey(_ code: Int, longPress: Bool = false) {
        guard isConnected else {
            log("⚠️ sendKey çağrıldı ama bağlı değil (code=\(code))")
            return
        }
        if longPress {
            sendDir(code, 1)
            Task { try? await Task.sleep(for: .milliseconds(600)); sendDir(code, 2) }
        } else {
            sendDir(code, 3)
        }
    }

    func disconnectPermanent() {
        log("🛑 disconnectPermanent çağrıldı")
        reconnectTask?.cancel(); reconnectTask = nil; cancelInternal()
    }

    // MARK: - TLS

    private func makeTLS(identity: SecIdentity) -> NWProtocolTLS.Options {
        let opts = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(opts.securityProtocolOptions, sec_identity_create(identity)!)
        sec_protocol_options_set_verify_block(opts.securityProtocolOptions, { _, _, complete in
            // TV self-signed cert kullanıyor, doğrulamayı bypass ediyoruz
            complete(true)
        }, .global())
        return opts
    }

    // MARK: - Receive

    private func startReceive() { receive() }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { Task { @MainActor in self.handleData(data) } }
            if err == nil && !done { Task { @MainActor in self.receive() } }
            else {
                if let err {
                    Task { @MainActor in
                        self.log("📡 Receive hata: \(err)")
                        if self.isCertError(err.localizedDescription) {
                            self.onCertError(err.localizedDescription)
                        } else {
                            self.onDisconnect()
                        }
                    }
                } else {
                    Task { @MainActor in self.onDisconnect() }
                }
            }
        }
    }

    private func handleData(_ data: Data) {
        receivedAnyData = true        // Bug 5: fallback configure için
        recvBuf.append(data)
        log("📥 raw(\(data.count)b): \(data.prefix(8).map { String(format:"%02x",$0) }.joined(separator:" "))")
        while !recvBuf.isEmpty {
            guard let (len, n) = decodeVarint(recvBuf, at: 0) else { break }
            // Bug 3: malformed packet koruması — 0 veya aşırı büyük length → buffer temizle
            guard len > 0 && len < 10_000 else {
                log("⚠️ Geçersiz mesaj uzunluğu (\(len)) — buffer temizleniyor")
                recvBuf.removeAll()
                return
            }
            guard recvBuf.count >= n + len else {
                log("⏸ Mesaj henüz tam değil (buf=\(recvBuf.count)b, beklenen=\(n + len)b)")
                break
            }
            let msg = recvBuf[n..<(n + len)]
            recvBuf.removeSubrange(..<(n + len))
            log("📨 msg(\(len)b): \(msg.prefix(12).map { String(format:"%02x",$0) }.joined(separator:" "))")
            handleMsg(Data(msg))
        }
    }

    // MARK: - Message dispatch
    // tag = msg[0] = (field_number << 3) | wire_type

    private func handleMsg(_ msg: Data) {
        guard !msg.isEmpty else { log("⚠️ Boş mesaj geldi"); return }
        let tag = msg[msg.startIndex]
        let tagHex = String(format: "0x%02X", tag)

        switch tag {

        case 0x0A: // field 1 = remote_configure
            guard !configured else {
                log("ℹ️ remote_configure tekrar geldi, ignore (zaten configured)")
                return
            }
            configured = true
            if let tvCode1 = parseField1Varint(msg) {
                // referans: active_features &= supported_features
                activeFeatures = 611 & tvCode1
                log("📺 remote_configure ← TV code1=\(tvCode1), bizim activeFeatures=\(activeFeatures)")
            } else {
                log("📺 remote_configure ← TV (code1 parse edilemedi, default=611)")
            }
            sendConfigure()
            // NOT: set_active göndermiyoruz, TV bize 0x12 (remote_set_active) gönderecek

        case 0x12: // field 2 = remote_set_active
            log("🤝 remote_set_active ← TV → cevap: active=\(activeFeatures)")
            sendSetActive()

        case 0x1A: // field 3 = remote_error (bu set_active DEĞİL!)
            let errBytes = msg.dropFirst().prefix(8).map { String(format:"%02x",$0) }.joined(separator:" ")
            log("⚠️ remote_error ← TV: \(errBytes)")

        case 0x42: // field 8 = remote_ping_request
            lastPingTime = Date()     // Bug 1: ghost connection için timestamp güncelle
            sendPong(msg)

        case 0x4A: // field 9 = remote_ping_response (TV bizim ping'imize cevap verirse)
            log("🏓 remote_ping_response geldi")

        case 0x52: // field 10 = remote_key_inject (TV tarafından echo)
            log("🔑 remote_key_inject echo geldi")

        default:
            // 2-byte tag kontrolü: remote_start = field 40 → 0xC2, 0x02
            if tag == 0xC2 && msg.count >= 2 && msg[msg.startIndex + 1] == 0x02 {
                log("🚀 remote_start ← TV — handshake tamamlandı! Komutlar gönderilebilir.")
                startPing()
            } else {
                log("❓ Bilinmeyen tag: \(tagHex) — tam msg: \(msg.prefix(8).map{String(format:"%02x",$0)}.joined(separator:" "))")
            }
        }
    }

    // MARK: - Protocol messages

    /// TV'nin remote_configure mesajından code1 (field 1, varint) okur.
    /// Yapı: [0x0A][varint innerLen][inner: 0x08 <varint code1> ...]
    private func parseField1Varint(_ msg: Data) -> Int? {
        guard msg.count >= 3 else { return nil }
        guard let (innerLen, n) = decodeVarint(msg, at: 1),
              msg.count >= 1 + n + innerLen else { return nil }
        let inner = Data(msg[(msg.startIndex + 1 + n)..<(msg.startIndex + 1 + n + innerLen)])
        guard inner.count >= 2, inner[inner.startIndex] == 0x08 else { return nil }
        guard let (code1, _) = decodeVarint(inner, at: 1) else { return nil }
        return code1
    }

    private func sendConfigure() {
        // RemoteMessage.remote_configure (field 1 → outer tag 0x0A):
        //   RemoteConfigure.code1       = activeFeatures      (field 1)
        //   RemoteConfigure.device_info = RemoteDeviceInfo    (field 2)
        //     RemoteDeviceInfo.unknown1     = 1               (field 3)
        //     RemoteDeviceInfo.unknown2     = "1"             (field 4)
        //     RemoteDeviceInfo.package_name = "atvremote"     (field 5)
        //     RemoteDeviceInfo.app_version  = "1.0.0"         (field 6)
        let info = ProtoWriter()
        info.writeVarint(field: 3, value: 1)
        info.writeString(field: 4, value: "1")
        info.writeString(field: 5, value: "atvremote")     // referans: "atvremote"
        info.writeString(field: 6, value: "1.0.0")

        let cfg = ProtoWriter()
        cfg.writeVarint(field: 1, value: activeFeatures)   // 611 veya TV & 611
        cfg.writeBytes(field: 2, value: info.toData())

        let outer = ProtoWriter()
        outer.writeBytes(field: 1, value: cfg.toData())    // field 1 = remote_configure

        let payload = outer.toData()
        log("📤 sendConfigure → code1=\(activeFeatures), payload(\(payload.count)b): \(payload.prefix(8).map{String(format:"%02x",$0)}.joined(separator:" "))")
        sendMsg(payload)
    }

    private func sendSetActive() {
        // RemoteMessage.remote_set_active (field 2 → outer tag 0x12):
        //   RemoteSetActive.active = activeFeatures  (field 1)
        let inner = ProtoWriter()
        inner.writeVarint(field: 1, value: activeFeatures)

        let outer = ProtoWriter()
        outer.writeBytes(field: 2, value: inner.toData())  // field 2 = remote_set_active (0x12)

        let payload = outer.toData()
        log("📤 sendSetActive → active=\(activeFeatures), payload(\(payload.count)b): \(payload.map{String(format:"%02x",$0)}.joined(separator:" "))")
        sendMsg(payload)
    }

    private func sendPong(_ ping: Data) {
        // RemoteMessage.remote_ping_response (field 9 → outer tag 0x4A):
        //   RemotePingResponse.val1 = ping.val1  (field 1)
        let val = parsePingVal(ping)
        let inner = ProtoWriter(); inner.writeVarint(field: 1, value: val)
        let outer = ProtoWriter(); outer.writeBytes(field: 9, value: inner.toData())
        sendMsg(outer.toData())
        log("🏓 ping ← val=\(val) → pong →")
    }

    /// ping msg[0]=0x42: [0x42][varint innerLen][inner: 0x08 <varint val1>]
    private func parsePingVal(_ msg: Data) -> Int {
        guard msg.count >= 3 else { return 0 }
        guard let (innerLen, n) = decodeVarint(msg, at: 1),
              msg.count >= 1 + n + innerLen, innerLen >= 2 else { return 0 }
        let inner = Data(msg[(msg.startIndex + 1 + n)..<(msg.startIndex + 1 + n + innerLen)])
        guard inner[inner.startIndex] == 0x08 else { return 0 }
        guard let (val, _) = decodeVarint(inner, at: 1) else { return 0 }
        return val
    }

    private func sendDir(_ code: Int, _ dir: Int) {
        // RemoteMessage.remote_key_inject (field 10 → outer tag 0x52):
        //   RemoteKeyInject.key_code  = code  (field 1)
        //   RemoteKeyInject.direction = dir   (field 2)
        let inner = ProtoWriter()
        inner.writeVarint(field: 1, value: code)
        inner.writeVarint(field: 2, value: dir)
        let outer = ProtoWriter()
        outer.writeBytes(field: 10, value: inner.toData())
        sendMsg(outer.toData())
        log("🎮 sendKey → code=\(code) dir=\(dir==1 ? "DOWN" : dir==2 ? "UP" : "SHORT")")
    }

    private func sendMsg(_ payload: Data) {
        guard let conn = connection, isConnected else {
            log("⚠️ sendMsg: bağlı değil, mesaj gönderilemedi")
            return
        }
        let frame = encodeVarint(payload.count) + payload
        conn.send(content: frame, completion: .idempotent)
    }

    // MARK: - Cert error detection
    // -9825 bad certificate, -9824 handshake fail, -9813 cert expired
    // iOS bazen sadece "handshake failed" veya "TLS alert" verir — hepsini yakala
    // Fix 1: sadece gerçek cert hataları — "98" ve geniş "tls" match kaldırıldı
    private func isCertError(_ desc: String) -> Bool {
        let d = desc.lowercased()
        return d.contains("-9825") || d.contains("-9824") || d.contains("-9813")
            || d.contains("9825")  || d.contains("9813")
            || d.contains("bad certificate")
            || d.contains("certificate unknown")
            || d.contains("handshake failure")
    }

    private func scheduleFallbackConfigure() {
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard isConnected, !configured, connection != nil else { return }
            if receivedAnyData {
                log("ℹ️ Fallback configure atlandı — TV mesaj gönderdi")
                return
            }
            configured = true
            log("⚡ Fallback configure — TV 4s içinde configure göndermedi")
            sendConfigure()
            try? await Task.sleep(for: .milliseconds(300))
            guard isConnected else { return }
            log("⚡ Fallback set_active gönderiliyor")
            sendSetActive()
        }
    }

    private func startPing() {
        pingTask?.cancel()
        pingTimeoutTask?.cancel()
        lastPingTime = Date()

        pingTimeoutTask = Task {
            while !Task.isCancelled && isConnected {
                try? await Task.sleep(for: .seconds(5))
                guard isConnected else { break }
                let elapsed = Date().timeIntervalSince(lastPingTime)
                if elapsed > 20 {
                    log("💀 Ping timeout (\(Int(elapsed))s) — ghost connection, disconnect")
                    onDisconnect()
                    break
                }
                log("💓 Bağlantı canlı — son ping: \(Int(elapsed))s önce")
            }
        }
    }

    private func onDisconnect() {
        // Fix 4: pairing açıkken reconnect başlatma
        guard !isPairing else {
            log("ℹ️ Pairing devam ediyor — reconnect atlandı")
            configured = false; isConnected = false
            pingTask?.cancel(); pingTimeoutTask?.cancel()
            return
        }
        guard isConnected || configured else { return }
        configured = false; isConnected = false
        pingTask?.cancel()
        pingTimeoutTask?.cancel()
        log("🔌 Bağlantı kesildi — reconnect başlatılıyor")
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !ip.isEmpty else { return }
            log("🔄 Yeniden bağlanmayı deniyorum → \(ip):\(port)")
            _ = await connect(ip: ip, port: port)
        }
    }

    private func onCertError(_ desc: String) {
        guard !certErrorFired else {
            log("ℹ️ Cert error zaten tetiklendi, yoksayılıyor")
            return
        }
        certErrorFired = true
        log("🔐 Cert hatası: \(desc)")
        reconnectTask?.cancel(); reconnectTask = nil
        pingTimeoutTask?.cancel()
        cancelInternal()
        onCertInvalid?()
    }

    private func cancelInternal() {
        pingTask?.cancel()
        pingTimeoutTask?.cancel()
        connection?.cancel(); connection = nil
        configured = false; isConnected = false
        recvBuf.removeAll(); receivedAnyData = false
        log("🧹 Internal state sıfırlandı")
    }

    private func log(_ msg: String) {
        print("[ATV] \(msg)"); onLog?(msg)
    }
}
