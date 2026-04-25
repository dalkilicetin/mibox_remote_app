import SwiftUI

extension Color {
    static let appBg      = Color(hex: "1a1a2e")
    static let cardBg     = Color(hex: "12122a")
    static let blueDeep   = Color(hex: "0f3460")
    static let blueDark   = Color(hex: "16213e")
    static let redAccent  = Color(hex: "e94560")
    static let greenOk    = Color(hex: "4ade80")
    static let blueInfo   = Color(hex: "60a5fa")
    static let terminalBg = Color(hex: "0a0a1a")

    init(hex: String) {
        var h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int & 0xFF)         / 255
        self.init(red: r, green: g, blue: b)
        _ = h // suppress warning
    }
}

// Android keyCodes
enum AtvKey {
    static let volumeUp   = 24
    static let volumeDown = 25
    static let home       = 3
    static let back       = 4
    static let dpadUp     = 19
    static let dpadDown   = 20
    static let dpadLeft   = 21
    static let dpadRight  = 22
    static let dpadCenter = 23
    static let playPause  = 85
    static let enter      = 66
    static let del        = 67
    static let wakeup     = 224  // ghost input — TV'yi aktif tutar, UI aksiyonu yok
}
