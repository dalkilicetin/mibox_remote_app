import Foundation
import Network
import Security

// MARK: - ATV Remote v2 Protocol (remotemessage.proto field mapping)
//
// RemoteMessage field → wire type 2 (length-delimited) tag bytes:
//   field  1  remote_configure     → 0x0A
//   field  2  remote_set_active    → 0x12
//   field  3  remote_error         → 0x1A
//   field  8  remote_ping_request  → 0x42
//   field  9  remote_ping_response → 0x4A
//   field 10  remote_key_inject    → 0x52
//   field 40  remote_start         → 0xC2, 0x02
//   field 50  remote_set_volume    → 0x92, 0x03
//
// Handshake sırası:
//   TV  → Client : remote_configure { code1: 623, device_info }
//   Client → TV  : remote_configure { code1: 611, device_info }
//   TV  → Client : remote_set_active { }
//   Client → TV  : remote_set_active { active: 611 }
//   TV  → Client : remote_start { started: true }
//   [komutlar gönderilebilir]

// MARK: - Input Queue (thread-safe)
// UI → queue → rate controller → network
// Buffer dolunca eski komutlar düşer — stale input istemiyoruz

// MARK: - AtvRemoteService

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
    private var lastPongTime = Date()
    private var receivedAnyData = false
    private var certErrorFired = false
    private var sessionId = UUID()
    private var isPairing = false

    // Dedicated network queue
    private let nwQueue = DispatchQueue(label: "atv.nw", qos: .userInteractive)

    // Exponential backoff
    private var reconnectAttempt = 0
    private let maxBackoffSeconds: TimeInterval = 30

    // Input pipeline — NavigationEngine
    private let navEngine = NavigationEngine()

    func setIdentity(_ id: SecIdentity) { identity = id; setupEngine() }

    func setupEngine() {
        navEngine.onDirection = { [weak self] code, dir in
            // Main thread dispatch burada — NavigationEngine bilmez
            Task { @MainActor [weak self] in
                self?.sendDir(code, dir)
            }
        }
    }

    func setPairing(_ active: Bool) {
        isPairing = active
        if active { reconnectTask?.cancel(); reconnectTask = nil }
    }

    // MARK: - Connect

    func connect(ip: String, port: Int = 6466) async -> Bool {
        self.ip = ip; self.port = port
        certErrorFired = false
        receivedAnyData = false
        let currentSession = UUID()
        sessionId = currentSession
        cancelInternal()
        guard let identity else { log("❌ Sertifika yok"); return false }

        log("🔌 Bağlanıyor → \(ip):\(port)")

        // TCP keepalive KAPALI — Google TV cevap vermiyor, bağlantıyı öldürüyor
        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.enableKeepalive = false
        tcpOpts.noDelay = true  // Nagle kapat — küçük paketler hemen gitsin

        let tlsOpts = makeTLS(identity: identity)
        let params  = NWParameters(tls: tlsOpts, tcp: tcpOpts)
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
                        guard self?.sessionId == currentSession else {
                            self?.log("⚠️ Eski session ready, ignore")
                            conn.cancel(); return
                        }
                        self?.isConnected = true
                        self?.reconnectAttempt = 0
                        self?.startReceive()
                        self?.scheduleFallbackConfigure()
                        // navEngine.start() remote_start handler'da çağrılır
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
            conn.start(queue: nwQueue)
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

    // MARK: - Public sendKey
    // UI buraya yazar — direkt network'e değil, input queue'ya

    func sendKey(_ code: Int, longPress: Bool = false) {
        if longPress {
            navEngine.push(code: code, dir: 1)
            navEngine.push(code: code, dir: 2)
            return
        }
        navEngine.push(code: code, dir: 3)
    }

    // Gyro/continuous input için — AirMouseView'dan direkt çağrılır
    // dx/dy normalize edilir: NavigationEngine -1...1 arası bekliyor
    func updateGyro(dx: Float, dy: Float) {
        let scale: Float = 50.0
        let nx = max(-1, min(1, dx / scale))
        let ny = max(-1, min(1, dy / scale))
        navEngine.update(dx: nx, dy: ny)
    }

    func disconnectPermanent() {
        log("🛑 disconnectPermanent çağrıldı")
        reconnectAttempt = 0
        navEngine.stop()
        reconnectTask?.cancel(); reconnectTask = nil
        cancelInternal()
    }

    // MARK: - TLS

    private func makeTLS(identity: SecIdentity) -> NWProtocolTLS.Options {
        let opts = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(opts.securityProtocolOptions, sec_identity_create(identity)!)
        sec_protocol_options_set_verify_block(opts.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, .global())
        return opts
    }

    // MARK: - Receive

    private func startReceive() { receive() }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { Task { @MainActor in self.lastPingTime = Date(); self.handleData(data) } }
            if let err {
                Task { @MainActor in
                    self.log("📡 Receive hata: \(err)")
                    if self.isCertError(err.localizedDescription) {
                        self.onCertError(err.localizedDescription)
                    } else {
                        self.onDisconnect()
                    }
                }
            } else if done {
                Task { @MainActor in
                    self.log("⚠️ Receive done — bağlantı kapandı")
                    self.onDisconnect()
                }
            } else {
                Task { @MainActor in self.receive() }
            }
        }
    }

    private func handleData(_ data: Data) {
        receivedAnyData = true
        lastPingTime = Date()
        recvBuf.append(data)
        while !recvBuf.isEmpty {
            guard let (len, n) = decodeVarint(recvBuf, at: 0) else { break }
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
            handleMsg(Data(msg))
        }
    }

    // MARK: - Message dispatch

    private func handleMsg(_ msg: Data) {
        guard !msg.isEmpty else { return }
        let tag = msg[msg.startIndex]
        let tagHex = String(format: "0x%02X", tag)

        switch tag {
        case 0x0A:
            guard !configured else { return }
            configured = true
            if let tvCode1 = parseField1Varint(msg) {
                activeFeatures = 611 & tvCode1
                log("📺 remote_configure ← TV code1=\(tvCode1), bizim activeFeatures=\(activeFeatures)")
            }
            sendConfigure()

        case 0x12:
            log("🤝 remote_set_active ← TV → cevap: active=\(activeFeatures)")
            sendSetActive()

        case 0x1A:
            let errBytes = msg.dropFirst().prefix(8).map { String(format:"%02x",$0) }.joined(separator:" ")
            log("⚠️ remote_error ← TV: \(errBytes)")

        case 0x42:
            lastPingTime = Date()
            lastPongTime = Date()
            sendPong(msg)

        case 0x4A:
            lastPongTime = Date()

        case 0x52:
            break  // echo, ignore

        default:
            if tag == 0xC2 && msg.count >= 2 && msg[msg.startIndex + 1] == 0x02 {
                log("🚀 remote_start ← TV — handshake tamamlandı!")
                startPing()
                navEngine.start()   // handshake tamam → input gönderebiliriz
            } else {
                log("❓ Bilinmeyen tag: \(tagHex) — \(msg.prefix(8).map{String(format:"%02x",$0)}.joined(separator:" "))")
            }
        }
    }

    // MARK: - Protocol messages

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
        let info = ProtoWriter()
        info.writeVarint(field: 3, value: 1)
        info.writeString(field: 4, value: "1")
        info.writeString(field: 5, value: "atvremote")
        info.writeString(field: 6, value: "1.0.0")
        let cfg = ProtoWriter()
        cfg.writeVarint(field: 1, value: activeFeatures)
        cfg.writeBytes(field: 2, value: info.toData())
        let outer = ProtoWriter()
        outer.writeBytes(field: 1, value: cfg.toData())
        let payload = outer.toData()
        log("📤 sendConfigure → code1=\(activeFeatures), payload(\(payload.count)b): \(payload.prefix(8).map{String(format:"%02x",$0)}.joined(separator:" "))")
        sendMsg(payload)
    }

    private func sendSetActive() {
        let inner = ProtoWriter()
        inner.writeVarint(field: 1, value: activeFeatures)
        let outer = ProtoWriter()
        outer.writeBytes(field: 2, value: inner.toData())
        let payload = outer.toData()
        log("📤 sendSetActive → active=\(activeFeatures), payload(\(payload.count)b): \(payload.map{String(format:"%02x",$0)}.joined(separator:" "))")
        sendMsg(payload)
    }

    private func sendPong(_ ping: Data) {
        let val = parsePingVal(ping)
        let inner = ProtoWriter(); inner.writeVarint(field: 1, value: val)
        let outer = ProtoWriter(); outer.writeBytes(field: 9, value: inner.toData())
        sendMsg(outer.toData())
        log("🏓 ping ← val=\(val) → pong →")
    }

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
        let inner = ProtoWriter()
        inner.writeVarint(field: 1, value: code)
        inner.writeVarint(field: 2, value: dir)
        let outer = ProtoWriter()
        outer.writeBytes(field: 10, value: inner.toData())
        sendMsg(outer.toData())
    }

    private func sendMsg(_ payload: Data) {
        guard let conn = connection, isConnected else { return }
        let frame = encodeVarint(payload.count) + payload
        conn.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                Task { @MainActor in
                    self.log("📡 Send hatası: \(error) — disconnect")
                    self.onDisconnect()
                }
            }
        })
    }

    // MARK: - Cert error

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

    // MARK: - Ping (sadece TV→biz yönü)
    // Biz ping GÖNDERMİYORUZ — TV remote_error döndürüp bağlantıyı kesiyor
    // Android TV bazen dakikalarca sessiz kalır — bu normaldir
    // Disconnect sadece TCP error'da olur

    private func startPing() {
        pingTask?.cancel()
        pingTimeoutTask?.cancel()
        lastPingTime = Date()
        lastPongTime = Date()

        pingTimeoutTask = Task {
            while !Task.isCancelled && isConnected {
                try? await Task.sleep(for: .seconds(30))
                guard isConnected else { break }
                let elapsed = Date().timeIntervalSince(lastPongTime)
                log("💓 Son TV verisi: \(Int(elapsed))s önce")
            }
        }
    }

    // MARK: - Disconnect / Reconnect (Exponential Backoff)

    private func onDisconnect() {
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
        navEngine.stop()  // reconnect'te remote_start'ta yeniden başlar

        let delay = min(0.5 * pow(2.0, Double(reconnectAttempt)), maxBackoffSeconds)
        reconnectAttempt += 1
        log("🔌 Bağlantı kesildi — \(String(format: "%.1f", delay))s sonra tekrar (deneme #\(reconnectAttempt))")

        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, !ip.isEmpty else { return }
            log("🔄 Yeniden bağlanıyorum → \(ip):\(port)")
            _ = await connect(ip: ip, port: port)
        }
    }

    private func onCertError(_ desc: String) {
        guard !certErrorFired else { return }
        certErrorFired = true
        log("🔐 Cert hatası: \(desc)")
        reconnectAttempt = 0
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
        onLog?(msg)
    }
}
