import Foundation
import Network
import Security

// MARK: - ATV Remote v2 Protocol Notes
//
// Gerçek handshake sırası (androidtvremote2 debug loglarından doğrulandı):
//
//   [TLS bağlantı kurulur]
//   TV  → Client : remote_configure { code1: 623, device_info: {...} }   tag=0x0A
//   Client → TV  : remote_configure { code1: 611, device_info: {...} }
//   TV  → Client : remote_set_active { }                                  tag=0x1A
//   Client → TV  : remote_set_active { active: 611 }
//   TV  → Client : remote_start { ... }                                   tag=0x12
//   [komutlar gönderilebilir]
//
// Ping/Pong: TV field-8 ping gönderir, client field-9 pong ile aynı val'i echo'lar.
// Key:       field-10 → { field-1: keyCode, field-2: direction }
//            direction: 1=DOWN, 2=UP, 3=SHORT (down+up birleşik)

@MainActor
final class AtvRemoteService: ObservableObject {
    @Published var isConnected = false
    var onLog: ((String) -> Void)?

    private var connection: NWConnection?
    private var recvBuf = Data()
    private var configured = false
    private var setActiveCode = 611   // TV'den gelen code1'e göre güncellenir
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var ip = ""
    private var port = 6466
    private var identity: SecIdentity?

    func setIdentity(_ id: SecIdentity) { identity = id }

    // MARK: - Connect

    func connect(ip: String, port: Int = 6466) async -> Bool {
        self.ip = ip; self.port = port
        cancelInternal()
        guard let identity else { log("Sertifika yok"); return false }

        let tlsOpts = makeTLS(identity: identity)
        let params  = NWParameters(tls: tlsOpts, tcp: .init())
        let conn    = NWConnection(host: .init(ip), port: .init(rawValue: UInt16(port))!, using: params)
        connection  = conn

        return await withCheckedContinuation { cont in
            var done = false
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !done else { return }; done = true
                    Task { @MainActor in
                        self?.isConnected = true
                        self?.startReceive()
                        self?.scheduleFallbackConfigure()
                        self?.startPing()
                        self?.log("Bağlandı: \(ip):\(port)")
                        cont.resume(returning: true)
                    }
                case .failed(let e):
                    guard !done else { return }; done = true
                    Task { @MainActor in self?.log("Hata: \(e)"); self?.onDisconnect() }
                    cont.resume(returning: false)
                case .cancelled:
                    guard !done else { return }; done = true
                    cont.resume(returning: false)
                default: break
                }
            }
            conn.start(queue: .global())
            Task {
                try? await Task.sleep(for: .seconds(5))
                guard !done else { return }; done = true; conn.cancel(); cont.resume(returning: false)
            }
        }
    }

    func sendKey(_ code: Int, longPress: Bool = false) {
        guard isConnected else { return }
        if longPress {
            sendDir(code, 1)
            Task { try? await Task.sleep(for: .milliseconds(600)); sendDir(code, 2) }
        } else {
            sendDir(code, 3)
        }
    }

    func disconnectPermanent() { reconnectTask?.cancel(); reconnectTask = nil; cancelInternal() }

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
            if let data { Task { @MainActor in self.handleData(data) } }
            if err == nil && !done { self.receive() }
            else { Task { @MainActor in self.onDisconnect() } }
        }
    }

    private func handleData(_ data: Data) {
        recvBuf.append(data)
        log("← raw(\(data.count)b): \(data.prefix(8).map { String(format:"%02x",$0) }.joined(separator:" "))")
        while !recvBuf.isEmpty {
            guard let (len, n) = decodeVarint(recvBuf, at: 0), recvBuf.count >= n + len else { break }
            let msg = recvBuf[n..<(n + len)]
            recvBuf.removeSubrange(..<(n + len))
            log("← msg(\(len)b): \(msg.prefix(8).map { String(format:"%02x",$0) }.joined(separator:" "))")
            handleMsg(Data(msg))
        }
    }

    private func handleMsg(_ msg: Data) {
        guard !msg.isEmpty else { return }
        switch msg[msg.startIndex] {

        case 0x0A: // remote_configure — TV kendi desteklediği feature set'ini bildiriyor
            guard !configured else { return }
            configured = true
            // TV'den gelen code1'i parse edip setActiveCode'a yaz.
            // Mesaj: 0x0A <varint len> <inner: 0x08 <varint code1> ...>
            if let tvCode1 = parseInnerCode1(msg) {
                setActiveCode = tvCode1
                log("← remote_configure (TV) code1=\(tvCode1)")
            } else {
                setActiveCode = 611
                log("← remote_configure (TV) code1=parse_failed, default=611")
            }
            sendConfigure()
            // NOT: set_active'yi burada GÖNDERMIYORUZ.
            // TV configure'a cevaben remote_set_active {} gönderecek (tag=0x1A),
            // biz ona cevap vereceğiz. Erken göndermek TV handshake state machine'ini bozuyor.

        case 0x1A: // remote_set_active — TV "hazırım, seni tanıdım" diyor
            log("← remote_set_active (TV) → cevap: active=\(setActiveCode)")
            sendSetActive()

        case 0x12: // remote_start — handshake tamamlandı, komut gönderilebilir
            log("✓ remote_start — bağlantı hazır")

        case 0x42: // ping
            sendPong(msg)

        case 0x4A: break // volume / app info bilgisi, şimdilik ignore

        default:
            log("← unknown tag: 0x\(String(format:"%02x", msg[msg.startIndex]))")
        }
    }

    // MARK: - Protocol messages

    /// TV'nin remote_configure mesajının inner payload'ından code1'i çıkarır.
    /// msg yapısı: [0x0A] [varint innerLen] [inner: 0x08 <varint code1> 0x12 <len> <device_info>]
    private func parseInnerCode1(_ msg: Data) -> Int? {
        guard msg.count >= 3 else { return nil }
        guard let (innerLen, n) = decodeVarint(msg, at: 1),
              msg.count >= 1 + n + innerLen else { return nil }
        let inner = Data(msg[(msg.startIndex + 1 + n)..<(msg.startIndex + 1 + n + innerLen)])
        // inner[0] = 0x08 (field 1, wire type 0 = varint)
        guard inner.count >= 2, inner[inner.startIndex] == 0x08 else { return nil }
        guard let (code1, _) = decodeVarint(inner, at: 1) else { return nil }
        return code1
    }

    private func sendConfigure() {
        // device_info (inner message, OuterMessage.remote_configure.device_info):
        //   field 3 (unknown1) : 1
        //   field 4 (unknown2) : "1"
        //   field 5 (package_name) : kendi app bundle id — TV'nin paketi değil!
        //   field 6 (app_version) : "1.0.0"
        let info = ProtoWriter()
        info.writeVarint(field: 3, value: 1)
        info.writeString(field: 4, value: "1")
        info.writeString(field: 5, value: "com.mibox.remote")
        info.writeString(field: 6, value: "1.0.0")

        // remote_configure:
        //   field 1 (code1) : 611 — client'ın desteklediği feature bitmask (referans değer)
        //   field 2 (device_info) : yukarıdaki info
        let cfg = ProtoWriter()
        cfg.writeVarint(field: 1, value: 611)
        cfg.writeBytes(field: 2, value: info.toData())

        // OuterMessage field 1 = remote_configure
        let outer = ProtoWriter()
        outer.writeBytes(field: 1, value: cfg.toData())

        sendMsg(outer.toData()); log("→ remote_configure code1=611")
    }

    private func sendSetActive() {
        // OuterMessage field 3 = remote_set_active { active: setActiveCode }
        let inner = ProtoWriter()
        inner.writeVarint(field: 1, value: setActiveCode)

        let outer = ProtoWriter()
        outer.writeBytes(field: 3, value: inner.toData())

        sendMsg(outer.toData()); log("→ remote_set_active active=\(setActiveCode)")
    }

    private func sendPong(_ ping: Data) {
        // Ping: OuterMessage field-8 (tag=0x42) → { field-1: val }
        // Pong: OuterMessage field-9 (tag=0x4A) → { field-1: val }  (aynı val'i echo'la)
        let val = parsePingVal(ping)
        let inner = ProtoWriter(); inner.writeVarint(field: 1, value: val)
        let outer = ProtoWriter(); outer.writeBytes(field: 9, value: inner.toData())
        sendMsg(outer.toData())
        log("← ping val=\(val) → pong")
    }

    /// ping mesajından (msg[0]=0x42) inner val1'i varint-aware şekilde parse et
    private func parsePingVal(_ msg: Data) -> Int {
        // msg: [0x42] [varint innerLen] [inner: 0x08 <varint val>]
        guard msg.count >= 3 else { return 0 }
        guard let (innerLen, n) = decodeVarint(msg, at: 1),
              msg.count >= 1 + n + innerLen, innerLen >= 2 else { return 0 }
        let inner = Data(msg[(msg.startIndex + 1 + n)..<(msg.startIndex + 1 + n + innerLen)])
        guard inner[inner.startIndex] == 0x08 else { return 0 }
        guard let (val, _) = decodeVarint(inner, at: 1) else { return 0 }
        return val
    }

    private func sendDir(_ code: Int, _ dir: Int) {
        // OuterMessage field-10 → RemoteKeyEvent { key_code: code, direction: dir }
        let inner = ProtoWriter()
        inner.writeVarint(field: 1, value: code)
        inner.writeVarint(field: 2, value: dir)
        let outer = ProtoWriter()
        outer.writeBytes(field: 10, value: inner.toData())
        sendMsg(outer.toData())
        log("→ key \(code) dir \(dir)")
    }

    private func sendMsg(_ payload: Data) {
        guard let conn = connection, isConnected else { return }
        conn.send(content: encodeVarint(payload.count) + payload, completion: .idempotent)
    }

    // Bağlandıktan 3 saniye sonra hâlâ TV configure göndermemişse biz başlatıyoruz.
    // (Bazı TV modelleri veya eski firmware'ler geç gönderebilir.)
    private func scheduleFallbackConfigure() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard isConnected, !configured else { return }
            configured = true
            log("→ fallback configure (TV configure göndermedi, biz başlatıyoruz)")
            sendConfigure()
            // Fallback'te set_active'yi de biz gönderiyoruz çünkü 0x1A gelmeyebilir
            try? await Task.sleep(for: .milliseconds(300))
            sendSetActive()
        }
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task {
            // TV kendi ping'ini gönderir (her ~5s), biz pong'larız (handleMsg 0x42).
            // Bu task sadece bağlantı canlılık kontrolü için tutuldu.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard isConnected else { break }
            }
        }
    }

    private func onDisconnect() {
        configured = false; isConnected = false
        pingTask?.cancel(); log("Bağlantı kesildi")
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !ip.isEmpty else { return }
            _ = await connect(ip: ip, port: port)
        }
    }

    private func cancelInternal() {
        pingTask?.cancel(); connection?.cancel(); connection = nil
        configured = false; isConnected = false; recvBuf.removeAll()
    }

    private func log(_ msg: String) {
        print("[ATV] \(msg)"); onLog?(msg)
    }
}
