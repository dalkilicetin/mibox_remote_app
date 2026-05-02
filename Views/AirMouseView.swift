import SwiftUI
import CoreMotion

struct AirMouseView: View {
    let atv: AtvRemoteService

    @State private var debugText     = "Hazır"
    @State private var sensitivity: Double = 15   // eşik açısı (derece)
    @State private var kbdVisible    = false
    @State private var kbdText       = ""

    // Gyro aktif mi
    @State private var gyroActive    = false

    // Basma anındaki referans açılar
    @State private var refBeta:  Double = 0
    @State private var refAlpha: Double = 0

    // Sürekli gönderme task'ı
    @State private var repeatTask: Task<Void, Never>? = nil

    // Çift tık
    @State private var lastTapTime: Date = .distantPast
    private let doubleTapInterval: TimeInterval = 0.35

    // Mevcut yön (repeat loop için)
    @State private var currentKey: Int? = nil

    private let motion = CMMotionManager()

    // Eşik açısı (derece) — bu kadar eğilince komut başlar
    private let angleThreshold: Double = 25

    // Hız kademeleri: (açı_eşiği, tekrar_ms)
    private let speedLevels: [(angle: Double, ms: UInt64)] = [
        ( 25,  400),   // hafif eğim  → yavaş
        ( 40,  250),   // orta eğim  → orta
        ( 55,  120),   // dik eğim   → hızlı
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.appBg.ignoresSafeArea()

            VStack(spacing: 0) {
                debugBar()

                VStack(spacing: 12) {
                    gyroPad()
                        .frame(maxHeight: .infinity)

                    actionButtons()
                        .frame(height: 100)

                    keyboardButton()
                        .frame(height: 52)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if kbdVisible {
                KeyboardPopup(
                    text: $kbdText,
                    isVisible: $kbdVisible,
                    onSend: sendText,
                    onBackspace: { atv.sendKey(67) },
                    onEnter:     { atv.sendKey(66) }
                )
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear   { startSensors() }
        .onDisappear { stopSensors() }
    }

    // MARK: - Debug bar

    private func debugBar() -> some View {
        Text(debugText)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.greenOk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color.terminalBg)
    }

    // MARK: - Gyro Pad

    private func gyroPad() -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28)
                .fill(gyroActive ? Color.redAccent : Color.blueDark)
                .animation(.easeInOut(duration: 0.15), value: gyroActive)

            RoundedRectangle(cornerRadius: 28)
                .stroke(gyroActive ? Color.white.opacity(0.3) : Color.redAccent, lineWidth: 2)

            VStack(spacing: 8) {
                Image(systemName: gyroActive ? "gyroscope" : "hand.tap")
                    .font(.system(size: 36))
                    .foregroundColor(.white)

                Text(gyroActive ? "Yönlendiriyor..." : "Basılı Tut")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                Text("Çift tık → Seç")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !gyroActive { activateGyro() }
                }
                .onEnded { _ in
                    deactivateGyro()
                    handleTap()
                }
        )
    }

    // MARK: - Gyro aç/kapat

    private func activateGyro() {
        gyroActive = true
        // Şu anki açıyı referans al
        refBeta  = lastBeta
        refAlpha = lastAlpha
        currentKey = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        debugText = "🎯 Gyro aktif"
        startRepeatLoop()
    }

    private func deactivateGyro() {
        gyroActive = false
        currentKey = nil
        repeatTask?.cancel()
        repeatTask = nil
        debugText = "Hazır"
    }

    // MARK: - Repeat loop
    // Gyro aktifken sürekli çalışır, currentKey'e göre komut gönderir

    private func startRepeatLoop() {
        repeatTask?.cancel()
        repeatTask = Task {
            while !Task.isCancelled {
                guard gyroActive, let key = currentKey else {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                atv.sendKey(key)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()

                // Hız: mevcut açıya göre interval belirle
                let interval = repeatInterval()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func repeatInterval() -> UInt64 {
        let dBeta  = lastBeta  - refBeta
        let dAlpha = lastAlpha - refAlpha
        let angle  = max(abs(dBeta), abs(dAlpha))

        // En yüksek kademeden başa doğru bak
        for level in speedLevels.reversed() {
            if angle >= level.angle {
                return level.ms * 1_000_000
            }
        }
        return speedLevels[0].ms * 1_000_000
    }

    // MARK: - Çift tık

    private func handleTap() {
        let now = Date()
        if now.timeIntervalSince(lastTapTime) < doubleTapInterval {
            atv.sendKey(AtvKey.dpadCenter)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            debugText = "✅ Seçildi"
            lastTapTime = .distantPast
        } else {
            lastTapTime = now
        }
    }

    // MARK: - Sensors

    // Son okunan açılar (referans için)
    @State private var lastBeta:  Double = 0
    @State private var lastAlpha: Double = 0

    private func startSensors() {
        motion.stopDeviceMotionUpdates()
        guard motion.isDeviceMotionAvailable else {
            debugText = "⚠️ Gyro yok"
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { data, _ in
            guard let d = data else { return }
            lastBeta  = d.attitude.pitch * 180 / .pi
            lastAlpha = d.attitude.yaw   * 180 / .pi
            if gyroActive { updateDirection() }
        }
    }

    private func stopSensors() {
        motion.stopDeviceMotionUpdates()
        repeatTask?.cancel()
    }

    // MARK: - Yön güncelle

    private func updateDirection() {
        var dBeta  = lastBeta  - refBeta
        var dAlpha = lastAlpha - refAlpha

        // Wrap fix (yaw 180/-180 sınırı)
        if dAlpha >  180 { dAlpha -= 360 }
        if dAlpha < -180 { dAlpha += 360 }

        let absBeta  = abs(dBeta)
        let absAlpha = abs(dAlpha)

        // Eşik altındaysa dur
        guard absBeta >= angleThreshold || absAlpha >= angleThreshold else {
            if currentKey != nil {
                currentKey = nil
                debugText = "🎯 Gyro aktif"
            }
            return
        }

        // Dominant eksen
        let newKey: Int
        if absBeta >= absAlpha {
            newKey = dBeta > 0 ? AtvKey.dpadUp : AtvKey.dpadDown
        } else {
            newKey = dAlpha > 0 ? AtvKey.dpadLeft : AtvKey.dpadRight
        }

        if newKey != currentKey {
            currentKey = newKey
            switch newKey {
            case AtvKey.dpadRight: debugText = "→ SAĞ"
            case AtvKey.dpadLeft:  debugText = "← SOL"
            case AtvKey.dpadDown:  debugText = "↓ AŞAĞI"
            case AtvKey.dpadUp:    debugText = "↑ YUKARI"
            default: break
            }
        }
    }

    // MARK: - Yardımcı butonlar

    private func actionButtons() -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                airBtn(icon: "arrow.backward", label: "Geri") { atv.sendKey(AtvKey.back) }
                airBtn(icon: "house",          label: "Home") { atv.sendKey(AtvKey.home) }
            }
            HStack(spacing: 12) {
                airBtn(icon: "speaker.plus",  label: "Ses+") { atv.sendKey(AtvKey.volumeUp) }
                airBtn(icon: "speaker.minus", label: "Ses-") { atv.sendKey(AtvKey.volumeDown) }
            }
        }
    }

    private func keyboardButton() -> some View {
        Button(action: { kbdVisible = true }) {
            Label("Klavye", systemImage: "keyboard")
                .foregroundColor(.greenOk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.greenOk))
        }
    }

    private func airBtn(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.system(size: 13))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color.blueDark)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blueDeep))
            .cornerRadius(14)
        }
    }

    private func sendText() {
        guard !kbdText.isEmpty else { return }
        kbdText = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
