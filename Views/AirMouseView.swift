import SwiftUI
import CoreMotion

struct AirMouseView: View {
    let atv: AtvRemoteService

    @State private var debugText  = "Hazır"
    @State private var kbdVisible = false
    @State private var kbdText    = ""

    // Gyro aktif mi
    @State private var gyroActive = false

    // Basma anındaki referans açılar
    @State private var refBeta:  Double = 0
    @State private var refAlpha: Double = 0

    // Son okunan açılar
    @State private var lastBeta:  Double = 0
    @State private var lastAlpha: Double = 0

    // Delta modu için son gönderilen açı
    @State private var deltaRefBeta:  Double = 0
    @State private var deltaRefAlpha: Double = 0

    // Repeat loop (açı modu)
    @State private var repeatTask: Task<Void, Never>? = nil
    @State private var currentKey: Int? = nil

    // Çift tık
    @State private var lastTapTime: Date = .distantPast
    private let doubleTapInterval: TimeInterval = 0.35

    // --- Eşikler ---
    private let deadZone:     Double = 15   // 0-15°   hiçbir şey
    private let deltaMaxAngle: Double = 30  // 15-30°  delta modu
    // 30°+  açı modu (repeat)

    // Delta modunda kaç derece harekette bir komut
    private let deltaStep: Double = 5

    // Açı modunda hız kademeleri
    private let speedLevels: [(angle: Double, ms: UInt64)] = [
        (30, 380),
        (45, 220),
        (60, 100),
    ]

    private let motion = CMMotionManager()

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.appBg.ignoresSafeArea()

            VStack(spacing: 0) {
                debugBar()
                VStack(spacing: 12) {
                    gyroPad().frame(maxHeight: .infinity)
                    actionButtons().frame(height: 100)
                    keyboardButton().frame(height: 52)
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
                .onChanged { _ in if !gyroActive { activateGyro() } }
                .onEnded   { _ in deactivateGyro(); handleTap() }
        )
    }

    // MARK: - Gyro aç/kapat

    private func activateGyro() {
        gyroActive = true
        refBeta  = lastBeta
        refAlpha = lastAlpha
        deltaRefBeta  = lastBeta
        deltaRefAlpha = lastAlpha
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

    // MARK: - Repeat loop (açı modu)

    private func startRepeatLoop() {
        repeatTask?.cancel()
        repeatTask = Task {
            while !Task.isCancelled {
                guard gyroActive, let key = currentKey else {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    continue
                }
                atv.sendKey(key)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                try? await Task.sleep(nanoseconds: repeatInterval())
            }
        }
    }

    private func repeatInterval() -> UInt64 {
        var dBeta  = lastBeta  - refBeta
        var dAlpha = lastAlpha - refAlpha
        if dAlpha >  180 { dAlpha -= 360 }
        if dAlpha < -180 { dAlpha += 360 }
        let angle = max(abs(dBeta), abs(dAlpha))
        for level in speedLevels.reversed() {
            if angle >= level.angle { return level.ms * 1_000_000 }
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

    private func startSensors() {
        motion.stopDeviceMotionUpdates()
        guard motion.isDeviceMotionAvailable else { debugText = "⚠️ Gyro yok"; return }
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

    // MARK: - Yön güncelle (iki mod)

    private func updateDirection() {
        var dBeta  = lastBeta  - refBeta
        var dAlpha = lastAlpha - refAlpha
        if dAlpha >  180 { dAlpha -= 360 }
        if dAlpha < -180 { dAlpha += 360 }

        let absBeta  = abs(dBeta)
        let absAlpha = abs(dAlpha)
        let maxAngle = max(absBeta, absAlpha)

        // Dead zone
        if maxAngle < deadZone {
            if currentKey != nil {
                currentKey = nil
                debugText = "🎯 Gyro aktif"
            }
            return
        }

        // Dominant eksen
        let dominantDelta = absBeta >= absAlpha ? dBeta : dAlpha
        let isVertical    = absBeta >= absAlpha

        let key: Int
        if isVertical {
            key = dBeta > 0 ? AtvKey.dpadUp : AtvKey.dpadDown
        } else {
            key = dAlpha > 0 ? AtvKey.dpadLeft : AtvKey.dpadRight
        }

        if maxAngle < deltaMaxAngle {
            // --- DELTA MODU ---
            // Repeat loop'u durdur
            currentKey = nil

            // Delta ref'e göre ne kadar hareket etti
            var dFromDeltaRef = isVertical
                ? lastBeta  - deltaRefBeta
                : lastAlpha - deltaRefAlpha

            if !isVertical {
                if dFromDeltaRef >  180 { dFromDeltaRef -= 360 }
                if dFromDeltaRef < -180 { dFromDeltaRef += 360 }
            }

            if abs(dFromDeltaRef) >= deltaStep {
                atv.sendKey(key)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                // Delta ref'i güncelle — bir sonraki adım buradan ölçülür
                if isVertical { deltaRefBeta  = lastBeta }
                else          { deltaRefAlpha = lastAlpha }

                switch key {
                case AtvKey.dpadRight: debugText = "→ SAĞ (Δ)"
                case AtvKey.dpadLeft:  debugText = "← SOL (Δ)"
                case AtvKey.dpadDown:  debugText = "↓ AŞAĞI (Δ)"
                case AtvKey.dpadUp:    debugText = "↑ YUKARI (Δ)"
                default: break
                }
            }
        } else {
            // --- AÇI MODU ---
            // Delta ref'i sürekli güncelle (moda geri dönünce sıfırdan başlasın)
            deltaRefBeta  = lastBeta
            deltaRefAlpha = lastAlpha

            if key != currentKey {
                currentKey = key
                switch key {
                case AtvKey.dpadRight: debugText = "→ SAĞ ●"
                case AtvKey.dpadLeft:  debugText = "← SOL ●"
                case AtvKey.dpadDown:  debugText = "↓ AŞAĞI ●"
                case AtvKey.dpadUp:    debugText = "↑ YUKARI ●"
                default: break
                }
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
