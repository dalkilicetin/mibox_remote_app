import Foundation
import Network
import Security

@MainActor
final class AtvRemoteService: ObservableObject {
    @Published var isConnected = false
    var onLog: ((String) -> Void)?

    private var connection: NWConnection?
    private var recvBuf = Data()
    private var configured = false
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
        case 0x0A:
            guard !configured else { return }
            configured = true; log("← configure (TV)")
            sendConfigure()
            // Android TV Remote v2 handshakes often expect a rapid response.
            // Sending SetActive immediately after configure is standard for some TV models.
            sendSetActive()
        case 0x1A:
            log("← handshake_ack (0x1a)")
        case 0x42:
            log("→ pong"); sendPong(msg)
        case 0x4A: break
        case 0x12:
            log("✓ Handshake tamamlandı")
        default:
            log("tag: 0x\(String(format:"%02x", msg[msg.startIndex]))")
        }
    }

    // MARK: - Protocol messages

    private func sendConfigure() {
        let info = ProtoWriter()
        info.writeVarint(field: 1, value: 1) // version
        info.writeString(field: 2, value: "MiBoxRemote")
        info.writeVarint(field: 3, value: 1) // capability
        info.writeString(field: 4, value: "1")
        info.writeString(field: 5, value: "com.google.android.tv.remote")
        info.writeString(field: 6, value: "1.0.0")

        let cfg = ProtoWriter()
        cfg.writeVarint(field: 1, value: 1)
        cfg.writeBytes(field: 2, value: info.toData())

        let msg = ProtoWriter()
        msg.writeBytes(field: 1, value: cfg.toData())

        sendMsg(msg.toData()); log("→ configure")
    }

    private func sendSetActive() {
        let a = ProtoWriter(); a.writeVarint(field: 1, value: 1)
        let m = ProtoWriter(); m.writeBytes(field: 2, value: a.toData())
        sendMsg(m.toData()); log("→ set_active")
    }

    private func sendPong(_ ping: Data) {
        let arr = Array(ping)
        var val = 0, shift = 0
        if arr.count >= 4 && arr[2] == 0x08 {
            for i in 3..<min(arr.count, 8) {
                val |= Int(arr[i] & 0x7F) << shift; shift += 7
                if arr[i] & 0x80 == 0 { break }
            }
        }
        let inner = ProtoWriter(); inner.writeVarint(field: 1, value: val)
        let outer = ProtoWriter(); outer.writeBytes(field: 9, value: inner.toData())
        sendMsg(outer.toData())
    }

    private func sendDir(_ code: Int, _ dir: Int) {
        let inner = ProtoWriter(); inner.writeVarint(field: 1, value: code); inner.writeVarint(field: 2, value: dir)
        let outer = ProtoWriter(); outer.writeBytes(field: 10, value: inner.toData())
        sendMsg(outer.toData())
        log("→ key \(code) dir \(dir)")
    }

    private func sendMsg(_ payload: Data) {
        guard let conn = connection, isConnected else { return }
        conn.send(content: encodeVarint(payload.count) + payload, completion: .idempotent)
    }

    private func scheduleFallbackConfigure() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard isConnected, !configured else { return }
            log("→ fallback configure")
            sendConfigure()
            try? await Task.sleep(for: .milliseconds(100))
            sendSetActive()
        }
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard isConnected else { break }
                connection?.send(content: Data([0x42,0x02,0x08,0x00]), completion: .idempotent)
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
