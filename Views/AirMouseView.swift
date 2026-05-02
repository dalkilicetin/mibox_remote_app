import SwiftUI
import CoreMotion

struct AirMouseView: View {
    let atv: AtvRemoteService

    @State private var debugText  = "Hazır"
    @State private var kbdVisible = false
    @State private var kbdText    = ""

    // Gyro aktif mi
    @State private var gyroActive = false

    // Referans açılar — her komut sonrası güncellenir
    @State private var refBeta:  Double = 0
    @State private var refAlpha: Double = 0

    // Son okunan açılar
    @State private var lastBeta:  Double = 0
    @State private var lastAlpha: Double = 0

    // Çift tık
    @State private var lastTapTime: Date = .distantPast
    private let doubleTapInterval: TimeInterval = 0.35

    // Eşik — bu kadar açı birikince bir D-pad komutu
    // Küçük = akıcı/hızlı, Büyük = yavaş/hassas
    private let pitchStep: Double = 8   // dikey: her 8° = 1 komut
    private let yawStep:   Double = 12  // yatay: her 12° = 1 komut
    private let deadZone:  Double = 4   // titremeleri filtrele

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
        // Basma anı = ilk referans
        refBeta  = lastBeta
        refAlpha = lastAlpha
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        debugText = "🎯 Hazır"
    }

    private func deactivateGyro() {
        gyroActive = false
        debugText = "Hazır"
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
            if gyroActive { processMotion() }
        }
    }

    private func stopSensors() {
        motion.stopDeviceMotionUpdates()
    }

    // MARK: - Hareket işle

    private func processMotion() {
        // Referanstan sapma
        var dBeta  = lastBeta  - refBeta
        var dAlpha = lastAlpha - refAlpha

        // Yaw wrap fix
        if dAlpha >  180 { dAlpha -= 360 }
        if dAlpha < -180 { dAlpha += 360 }

        // Dead zone — küçük titremeleri yoksay
        let absBeta  = abs(dBeta)
        let absAlpha = abs(dAlpha)

        var sent = false

        // Dikey — pitchStep kadar birikince komut
        if absBeta >= pitchStep {
            let key = dBeta > 0 ? AtvKey.dpadUp : AtvKey.dpadDown
            atv.sendKey(key)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // Referansı güncelle — bir adım ileri al
            refBeta = lastBeta
            debugText = dBeta > 0 ? "↑ YUKARI" : "↓ AŞAĞI"
            sent = true
        }

        // Yatay — yawStep kadar birikince komut
        if absAlpha >= yawStep {
            // Aynı anda dikey de aşıldıysa dominant olanı seç
            if !sent || absAlpha > absBeta {
                let key = dAlpha > 0 ? AtvKey.dpadLeft : AtvKey.dpadRight
                atv.sendKey(key)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                refAlpha = lastAlpha
                debugText = dAlpha > 0 ? "← SOL" : "→ SAĞ"
            } else {
                // Dikey dominant — yatay referansı da güncelle (drift önle)
                refAlpha = lastAlpha
            }
        }

        // Her iki eksen de dead zone'daysa debug güncelle
        if absBeta < deadZone && absAlpha < deadZone && !sent {
            debugText = "🎯 Hazır"
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
