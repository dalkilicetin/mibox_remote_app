import Foundation

struct DiscoveredDevice: Identifiable, Equatable, Hashable {
    var id: String { ip }
    let ip: String
    var hasCert: Bool
    var hasApk: Bool
    var pairingPort: Int
    var remotePort:  Int

    func hash(into hasher: inout Hasher) {
        hasher.combine(ip)
    }

    init(ip: String, hasCert: Bool = false, hasApk: Bool = false,
         pairingPort: Int = 6467, remotePort: Int = 6466) {
        self.ip          = ip
        self.hasCert     = hasCert
        self.hasApk      = hasApk
        self.pairingPort = pairingPort
        self.remotePort  = remotePort
    }

    static func == (l: Self, r: Self) -> Bool { l.ip == r.ip }
}
