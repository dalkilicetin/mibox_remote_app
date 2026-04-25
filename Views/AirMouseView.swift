import SwiftUI
import CoreMotion

struct AirMouseView: View {
    let apk: MiBoxService
    let atv: AtvRemoteService

    @State private var airOn         = false
    @State private var debugText     = "Hazır"
    @State private var sensitivity: Double = 25
    @State private var kbdVisible    = false
    @State private var kbdText       = ""
    @State private var swipeCooldown = false
    @State private var selectedTab   = 0   // 0=Air, 1=Kalibrasyon

    // Kalibrasyon
    @State private var activePtId: Int? = nil

    // Sensor timing
    @State private var lastTime: Date = Date()

    // Tap tracking
    @State private var tapStart   = CGPoint.zero
    @State private var tapLast    = CGPoint.zero
    @State private var tapTime    = Date()
    @State private var tapAccumV  = 0.0
    @State private var tapAccumH  = 0.0
    @State private var swipeAccum = 0.0

    private let motion = CMMotionManager()
    private let engine = InputEngine()

    private static let TAP_MAX_MOVE: Double = 12
    private static let TAP_MAX_MS   = 250
    private static let SCROLL_THRESH: Double = 65
    private static let SWIPE_THRESH:  Double = 40

    private let calibLabels = [
        "Sol Üst",  "Orta Üst", "Sağ Üst",
        "Sol Orta", "Merkez",   "Sağ Orta",
        "Sol Alt",  "Orta Alt", "Sağ Alt"
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.appBg.ignoresSafeArea()
            VStack(spacing: 0) {
                tabBar
                Group {
                    if selectedTab == 0 {
                        airMousePage()
                    } else {
                        calibrationPage()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if kbdVisible {
                KeyboardPopup(
                    text: $kbdText,
                    isVisible: $kbdVisible,
                    onSend: sendText,
                    onBackspace: { apk.sendKey(67) },
                    onEnter:     { apk.sendKey(66) }
                )
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear   { startSensors() }
        .onDisappear { stopSensors() }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(["Air Mouse", "Kalibrasyon"].enumerated()), id: \.offset) { idx, name in
                Button(action: { selectedTab = idx }) {
                    VStack(spacing: 4) {
                        Text(name)
                            .font(.system(size: 13))
                            .foregroundColor(selectedTab == idx ? .redAccent : .gray)
                        Rectangle()
                            .fill(selectedTab == idx ? Color.redAccent : .clear)
                            .frame(height: 2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 4)
        .background(Color.cardBg)
    }

    // MARK: - Air Mouse Page

    private func airMousePage() -> some View {
        VStack(spacing: 0) {
            debugBar()
            toggleButton()

            mainArea()
                .frame(maxHeight: .infinity)
                .layoutPriority(1)

            VStack(spacing: 4) {
                actionButtons()
                    .frame(height: 100)
                keyboardButton()
                    .frame(height: 52)
                sensitivitySlider()
                    .frame(height: 68)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func debugBar() -> some View {
        let calibStatus = engine.calibration.isReady
            ? "CAL:\(engine.calibration.pointCount)/9"
            : "DELTA"
        return Text("\(debugText) [\(calibStatus)]")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.greenOk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color.terminalBg)
    }

    private func toggleButton() -> some View {
        Button(action: toggleAir) {
            Text(airOn ? "Air Modu" : "Kumanda Modu")
                .foregroundColor(airOn ? .white : .redAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(airOn ? Color.redAccent : Color.blueDark)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.redAccent))
                .cornerRadius(20)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func mainArea() -> some View {
        HStack(spacing: 12) {
            tapArea()
            swipeBar()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxHeight: .infinity)
    }

    private func tapArea() -> some View {
        ZStack {
            Color.redAccent.cornerRadius(24)
            Text("TIKLA")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if tapLast == .zero {
                        tapStart = v.location; tapLast = v.location
                        tapTime = Date(); tapAccumV = 0; tapAccumH = 0
                    }
                    let dx = v.location.x - tapLast.x
                    let dy = v.location.y - tapLast.y
                    tapLast = v.location
                    tapAccumV += dy; tapAccumH += dx
                    if abs(tapAccumV) >= Self.SCROLL_THRESH {
                        apk.sendKey(tapAccumV > 0 ? 20 : 19)
                        apk.setScrollMode(1); tapAccumV = 0
                    }
                    if abs(tapAccumH) >= Self.SCROLL_THRESH {
                        apk.sendKey(tapAccumH > 0 ? 22 : 21)
                        apk.setScrollMode(2); tapAccumH = 0
                    }
                }
                .onEnded { v in
                    let moved = hypot(tapLast.x - tapStart.x, tapLast.y - tapStart.y)
                    let ms    = Int(Date().timeIntervalSince(tapTime) * 1000)
                    if moved < Self.TAP_MAX_MOVE && ms < Self.TAP_MAX_MS {
                        if airOn {
                            // Option 1: ATV protokolü üzerinden tap
                            // Cursor neredeyse focus oraya gitmiş olabilir
                            apk.moveCursor(dx: 0, dy: 0)  // cursor sync
                            apk.tap()                      // APK tap (deneme)
                            if atv.isConnected {
                                atv.sendKey(AtvKey.dpadCenter)  // ATV tap
                            }
                        } else {
                            sendKey(AtvKey.dpadCenter)
                        }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    tapLast = .zero; tapAccumV = 0; tapAccumH = 0
                }
        )
    }

    private func swipeBar() -> some View {
        VStack(spacing: 0) {
            Button(action: { sendSwipe(1) }) {
                Image(systemName: "chevron.up").foregroundColor(.redAccent)
                    .padding(10)
            }
            Rectangle().fill(Color.blueDeep).frame(width: 4).frame(maxHeight: .infinity)
            Button(action: { sendSwipe(-1) }) {
                Image(systemName: "chevron.down").foregroundColor(.redAccent)
                    .padding(10)
            }
        }
        .frame(width: 36)
        .background(Color(hex: "0d1117"))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blueDeep, lineWidth: 2))
        .cornerRadius(16)
        .gesture(DragGesture()
            .onChanged { v in
                swipeAccum += v.translation.height
                if abs(swipeAccum) >= Self.SWIPE_THRESH {
                    sendSwipe(swipeAccum > 0 ? -1 : 1); swipeAccum = 0
                }
            }
            .onEnded { _ in swipeAccum = 0 }
        )
    }

    private func actionButtons() -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                airBtn(icon: "arrow.backward", label: "Geri") { sendKey(AtvKey.back) }
                airBtn(icon: "house",          label: "Home") { sendKey(AtvKey.home) }
            }
            HStack(spacing: 12) {
                airBtn(icon: "speaker.plus",  label: "Ses+") { sendKey(AtvKey.volumeUp) }
                airBtn(icon: "speaker.minus", label: "Ses-") { sendKey(AtvKey.volumeDown) }
            }
        }
        .padding(.horizontal, 16)
    }

    private func keyboardButton() -> some View {
        Button(action: { kbdVisible = true }) {
            Label("Klavye", systemImage: "keyboard")
                .foregroundColor(.greenOk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.greenOk))
        }
        .padding(.horizontal, 16)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func airBtn(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.system(size: 13))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(Color.blueDark)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blueDeep))
            .cornerRadius(14)
        }
    }

    // MARK: - Calibration Page

    private func calibrationPage() -> some View {
        VStack(spacing: 12) {
            Text(activePtId == nil
                 ? "1. Nokta seç  2. Touchpad ile cursoru götür  3. Kaydet"
                 : "'\(calibLabels[activePtId!])': cursoru götür → Kaydet bas")
                .font(.system(size: 16))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            Text("Kalibrasyon: \(engine.calibration.pointCount)/9 \(engine.calibration.isReady ? "✓ Hazır" : "– Eksik")")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(engine.calibration.isReady ? .greenOk : Color(hex: "fbbf24"))

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                spacing: 8
            ) {
                ForEach(0..<9, id: \.self) { id in
                    calibDot(id: id)
                }
            }
            .padding(.horizontal, 16)

            Button(action: saveCalibPoint) {
                VStack(spacing: 4) {
                    Text("Kaydet").font(.system(size: 20, weight: .bold))
                    Text(activePtId != nil ? calibLabels[activePtId!] : "Önce nokta seç")
                        .font(.system(size: 16))
                }
                .foregroundColor(activePtId != nil ? .white : Color(hex: "666666"))
                .frame(maxWidth: .infinity)
                .frame(height: 100)
                .background(activePtId != nil ? Color.redAccent : Color(hex: "333333"))
                .cornerRadius(20)
            }
            .disabled(activePtId == nil)
            .padding(.horizontal, 16)

            Button(action: {
                engine.calibration.reset()
                activePtId = nil
            }) {
                Text("Kalibrasyonu Sıfırla")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.4)))
            }
            .padding(.horizontal, 16)

            Spacer()
        }
    }

    private func calibDot(id: Int) -> some View {
        let isSaved  = engine.calibration.points.contains { $0.id == id }
        let isActive = activePtId == id
        let parts    = calibLabels[id].components(separatedBy: " ")

        return Button(action: { activePtId = id }) {
            VStack(spacing: 3) {
                Text(parts.first ?? "").font(.system(size: 16, weight: .semibold))
                Text(parts.dropFirst().joined(separator: " ")).font(.system(size: 10))
                if isSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                }
            }
            .foregroundColor(isActive ? .redAccent : isSaved ? .greenOk : .gray)
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background(Color(hex: "0d1117"))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isActive ? Color.redAccent : isSaved ? Color.greenOk : Color.blueDeep,
                        lineWidth: 1.5
                    )
            )
            .cornerRadius(12)
        }
    }

    private func saveCalibPoint() {
        guard let id = activePtId else { return }
        // Fix 1: pipeline'dan geçmiş accDb/accDa — mutlak açı değil
        let point = CalibPoint(
            id: id,
            db: engine.lastAccDb,
            da: engine.lastAccDa,
            cx: Double(apk.cursorX),
            cy: Double(apk.cursorY)
        )
        engine.calibration.addPoint(point)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        activePtId = (id + 1) % 9
    }

    // MARK: - Sensors
    // Fix 2: CMDeviceMotion — Apple'ın sensor fusion, sync ve tutarlı

    private func startSensors() {
        motion.stopDeviceMotionUpdates()
        engine.reset()
        engine.screenW = Double(apk.screenW)
        engine.screenH = Double(apk.screenH)

        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(
            using: .xMagneticNorthZVertical,
            to: .main
        ) { data, _ in
            guard let d = data else { return }
            // attitude.pitch → dikey (beta), attitude.yaw → yatay (alpha)
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

        if !airOn {
            debugText = "pitch:\(String(format:"%.1f", beta)) yaw:\(String(format:"%.1f", alpha))"
            engine.reset()
            return
        }

        guard let (dx, dy) = engine.process(
            beta: beta,
            alpha: alpha,
            dt: dt,
            sensitivity: sensitivity
        ) else { return }

        apk.moveCursor(dx: dx, dy: dy)
        engine.onCursorUpdate(x: Double(apk.cursorX), y: Double(apk.cursorY))

        debugText = "dx:\(dx) dy:\(dy) \(engine.calibration.isReady ? "[MAP]" : "[DELTA]")"
    }

    // MARK: - Actions

    private func toggleAir() {
        airOn.toggle()
        engine.reset()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            if airOn { apk.showCursor() } else { apk.hideCursor() }
        }
    }

    private func sendKey(_ code: Int) {
        if atv.isConnected { atv.sendKey(code) } else { apk.sendKey(code) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func sendText() {
        guard !kbdText.isEmpty else { return }
        apk.sendText(kbdText); kbdText = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func sendSwipe(_ dir: Int) {
        guard !swipeCooldown else { return }
        swipeCooldown = true
        let cx = apk.cursorX, cy = apk.cursorY
        let y2 = max(50, min(apk.screenH - 50, cy - 150 * dir))
        apk.sendSwipe(x1: cx, y1: cy, x2: cx, y2: y2, duration: 100)
        apk.setScrollMode(1)
        Task { try? await Task.sleep(for: .milliseconds(200)); swipeCooldown = false }
    }
}
