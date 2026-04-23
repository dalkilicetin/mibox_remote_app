import Foundation

struct DiscoveredDevice: Identifiable, Equatable, Hashable {
    // id olarak MAC kullanıyoruz — IP değişebilir, MAC değişmez
    var id: String { mac ?? ip }
    let ip: String
    var mac: String?      // TV TLS sertifikasının CN'inden parse edilir
    var hasCert: Bool
    var hasApk: Bool
    var pairingPort: Int
    var remotePort:  Int

    // Cert lookup key: MAC varsa MAC, yoksa IP
    var certKey: String { mac ?? ip }

    func hash(into hasher: inout Hasher) {
        hasher.combine(mac ?? ip)
    }

    init(ip: String, mac: String? = nil, hasCert: Bool = false, hasApk: Bool = false,
         pairingPort: Int = 6467, remotePort: Int = 6466) {
        self.ip          = ip
        self.mac         = mac
        self.hasCert     = hasCert
        self.hasApk      = hasApk
        self.pairingPort = pairingPort
        self.remotePort  = remotePort
    }

    static func == (l: Self, r: Self) -> Bool {
        // MAC varsa MAC ile karşılaştır (IP değişse bile aynı cihaz)
        if let lm = l.mac, let rm = r.mac { return lm == rm }
        return l.ip == r.ip
    }
}
