import SwiftUI
import CoreMotion

struct AirMouseView: View {
    let atv: AtvRemoteService

    @State private var debugText      = "Hazır"
    @State private var sensitivity: Double = 25
    @State private var kbdVisible     = false
    @State private var kbdText        = ""

    // Gyro aktif mi (basılı tutuluyor mu)
    @State private var gyroActive     = false

    // Çift tık
    @State private var lastTapTime: Date = .distantPast

    // D-pad accumulator
    @State private var accumX: Double = 0
    @State private var accumY: Double = 0
    private let dpadThreshold: Double = 80   // düşük = daha duyarlı

    // Sensor timing
    @State private var lastTime: Date = Date()

    private let motion = CMMotionManager()
    private let engine = InputEngine()

    // Çift tık için max aralık
    private let doubleTapInterval: TimeInterval = 0.35

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

                    sensitivitySlider()
                        .frame(height: 68)
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
                    if !gyroActive {
                        activateGyro()
                    }
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
        engine.reset()   // basma anı = yeni referans noktası
        accumX = 0
        accumY = 0
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        debugText = "🎯 Gyro aktif"
    }

    private func deactivateGyro() {
        gyroActive = false
        accumX = 0
        accumY = 0
        engine.reset()
        debugText = "Hazır"
    }

    // MARK: - Çift tık

    private func handleTap() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTapTime)

        if elapsed < doubleTapInterval {
            // Çift tık → SELECT
            atv.sendKey(AtvKey.dpadCenter)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            debugText = "✅ Seçildi"
            lastTapTime = .distantPast   // üçüncü tık yeni döngü başlatsın
        } else {
            lastTapTime = now
        }
    }

    // MARK: - Sensors

    private func startSensors() {
        motion.stopDeviceMotionUpdates()
        engine.reset()

        guard motion.isDeviceMotionAvailable else {
            debugText = "⚠️ Gyro yok"
            return
        }

        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(
            using: .xMagneticNorthZVertical,
            to: .main
        ) { data, _ in
            guard let d = data else { return }
            let beta  = d.attitude.pitch * 180 / .pi
            let alpha = d.attitude.yaw   * 180 / .pi
            onSensorUpdate(beta: beta, alpha: alpha)
        }
    }

    private func stopSensors() {
        motion.stopDeviceMotionUpdates()
    }

    private func onSensorUpdate(beta: Double, alpha: Double) {
        let now = Date()
        let dt  = now.timeIntervalSince(lastTime)
        guard dt >= 0.016 else { return }
        lastTime = now

        guard gyroActive else {
            debugText = "pitch:\(String(format: "%.1f", beta)) yaw:\(String(format: "%.1f", alpha))"
            engine.reset()
            return
        }

        guard let (dx, dy) = engine.process(
            beta: beta,
            alpha: alpha,
            dt: dt,
            sensitivity: sensitivity
        ) else { return }

        accumX += Double(dx)
        accumY += Double(dy)

        // Dominant eksen — aynı anda ikisi aşıldıysa büyük olanı seç
        let xOver = abs(accumX) >= dpadThreshold
        let yOver = abs(accumY) >= dpadThreshold

        if xOver && yOver {
            // İkisi aşıldı — dominant olanı gönder, diğerini sıfırla
            if abs(accumX) >= abs(accumY) {
                sendDpad(accumX > 0 ? AtvKey.dpadRight : AtvKey.dpadLeft)
                accumX = 0
                accumY *= 0.5   // dikey birikimi azalt, sıfırlama
            } else {
                sendDpad(accumY > 0 ? AtvKey.dpadDown : AtvKey.dpadUp)
                accumY = 0
                accumX *= 0.5
            }
        } else if xOver {
            sendDpad(accumX > 0 ? AtvKey.dpadRight : AtvKey.dpadLeft)
            accumX = 0
        } else if yOver {
            sendDpad(accumY > 0 ? AtvKey.dpadDown : AtvKey.dpadUp)
            accumY = 0
        }
    }

    private func sendDpad(_ key: Int) {
        atv.sendKey(key)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch key {
        case AtvKey.dpadRight: debugText = "→ SAĞ"
        case AtvKey.dpadLeft:  debugText = "← SOL"
        case AtvKey.dpadDown:  debugText = "↓ AŞAĞI"
        case AtvKey.dpadUp:    debugText = "↑ YUKARI"
        default: break
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

    private func sensitivitySlider() -> some View {
        VStack(spacing: 4) {
            HStack {
                Text("Hassasiyet")
                    .font(.system(size: 16)).foregroundColor(.gray)
                Spacer()
                Text("\(Int(sensitivity))")
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.redAccent)
            }
            Slider(value: $sensitivity, in: 5...150).tint(.redAccent)
        }
        .padding(16)
        .background(Color.terminalBg)
        .cornerRadius(10)
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
