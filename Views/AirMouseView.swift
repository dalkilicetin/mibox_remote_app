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
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    tabBar(geo: geo)
                    if selectedTab == 0 {
                        airMousePage(geo: geo)
                    } else {
                        calibrationPage(geo: geo)
                    }
                }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appBg)
            .onAppear   { startSensors() }
            .onDisappear { stopSensors() }
        }
    }

    // MARK: - Tab bar

    private func tabBar(geo: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(["Air Mouse", "Kalibrasyon"].enumerated()), id: \.offset) { idx, name in
                Button(action: { selectedTab = idx }) {
                    VStack(spacing: 4) {
                        Text(name)
                            .font(.system(size: geo.size.width * 0.032))
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

    private func airMousePage(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            debugBar(geo: geo)
            toggleButton(geo: geo)
            mainArea(geo: geo)
            actionButtons(geo: geo)
            keyboardButton(geo: geo)
            sensitivitySlider(geo: geo)
        }
    }

    private func debugBar(geo: GeometryProxy) -> some View {
        let calibStatus = engine.calibration.isReady
            ? "CAL:\(engine.calibration.pointCount)/9"
            : "DELTA"
        return Text("\(debugText) [\(calibStatus)]")
            .font(.system(size: geo.size.width * 0.028, design: .monospaced))
            .foregroundColor(.greenOk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, geo.size.width * 0.03)
            .padding(.vertical, geo.size.height * 0.008)
            .background(Color.terminalBg)
    }

    private func toggleButton(geo: GeometryProxy) -> some View {
        Button(action: toggleAir) {
            Text(airOn ? "Air Modu" : "Kumanda Modu")
                .foregroundColor(airOn ? .white : .redAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, geo.size.height * 0.018)
                .background(airOn ? Color.redAccent : Color.blueDark)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.redAccent))
                .cornerRadius(20)
        }
        .padding(.horizontal, geo.size.width * 0.03)
        .padding(.top, geo.size.height * 0.012)
    }

    private func mainArea(geo: GeometryProxy) -> some View {
        HStack(spacing: geo.size.width * 0.02) {
            tapArea(geo: geo)
            swipeBar(geo: geo)
        }
        .padding(.horizontal, geo.size.width * 0.03)
        .padding(.vertical, geo.size.height * 0.012)
        .frame(maxHeight: .infinity)
    }

    private func tapArea(geo: GeometryProxy) -> some View {
        ZStack {
            Color.redAccent.cornerRadius(24)
            Text("TIKLA")
                .font(.system(size: geo.size.width * 0.07, weight: .bold))
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
                            apk.tap()
                            if atv.isConnected { atv.sendKey(AtvKey.dpadCenter) }
                        } else {
                            sendKey(AtvKey.dpadCenter)
                        }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    tapLast = .zero; tapAccumV = 0; tapAccumH = 0
                }
        )
    }

    private func swipeBar(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            Button(action: { sendSwipe(1) }) {
                Image(systemName: "chevron.up").foregroundColor(.redAccent)
                    .padding(geo.size.width * 0.015)
            }
            Rectangle().fill(Color.blueDeep).frame(width: 4).frame(maxHeight: .infinity)
            Button(action: { sendSwipe(-1) }) {
                Image(systemName: "chevron.down").foregroundColor(.redAccent)
                    .padding(geo.size.width * 0.015)
            }
        }
        .frame(width: geo.size.width * 0.09)
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

    private func actionButtons(geo: GeometryProxy) -> some View {
        VStack(spacing: geo.size.height * 0.008) {
            HStack(spacing: geo.size.width * 0.02) {
                airBtn(icon: "arrow.backward", label: "Geri", geo: geo) { sendKey(AtvKey.back) }
                airBtn(icon: "house",          label: "Home", geo: geo) { sendKey(AtvKey.home) }
            }
            HStack(spacing: geo.size.width * 0.02) {
                airBtn(icon: "speaker.plus",  label: "Ses+", geo: geo) { sendKey(AtvKey.volumeUp) }
                airBtn(icon: "speaker.minus", label: "Ses-", geo: geo) { sendKey(AtvKey.volumeDown) }
            }
        }
        .padding(.horizontal, geo.size.width * 0.03)
    }

    private func keyboardButton(geo: GeometryProxy) -> some View {
        Button(action: { kbdVisible = true }) {
            Label("Klavye", systemImage: "keyboard")
                .foregroundColor(.greenOk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, geo.size.height * 0.015)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.greenOk))
        }
        .padding(.horizontal, geo.size.width * 0.03)
        .padding(.top, geo.size.height * 0.008)
    }

    private func sensitivitySlider(geo: GeometryProxy) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text("Hassasiyet")
                    .font(.system(size: geo.size.width * 0.03)).foregroundColor(.gray)
                Spacer()
                Text("\(Int(sensitivity))")
                    .font(.system(size: geo.size.width * 0.03, weight: .bold)).foregroundColor(.redAccent)
            }
            Slider(value: $sensitivity, in: 5...150).tint(.redAccent)
        }
        .padding(geo.size.width * 0.03)
        .background(Color.terminalBg)
        .cornerRadius(10)
        .padding(.horizontal, geo.size.width * 0.03)
        .padding(.vertical, geo.size.height * 0.008)
    }

    private func airBtn(icon: String, label: String, geo: GeometryProxy, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: geo.size.width * 0.042))
                Text(label).font(.system(size: geo.size.width * 0.032))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: geo.size.height * 0.072)
            .background(Color.blueDark)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blueDeep))
            .cornerRadius(14)
        }
    }

    // MARK: - Calibration Page

    private func calibrationPage(geo: GeometryProxy) -> some View {
        VStack(spacing: geo.size.height * 0.015) {
            Text(activePtId == nil
                 ? "1. Nokta seç  2. Touchpad ile cursoru götür  3. Kaydet"
                 : "'\(calibLabels[activePtId!])': cursoru götür → Kaydet bas")
                .font(.system(size: geo.size.width * 0.03))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, geo.size.width * 0.04)
                .padding(.top, geo.size.height * 0.02)

            Text("Kalibrasyon: \(engine.calibration.pointCount)/9 \(engine.calibration.isReady ? "✓ Hazır" : "– Eksik")")
                .font(.system(size: geo.size.width * 0.032, weight: .semibold))
                .foregroundColor(engine.calibration.isReady ? .greenOk : Color(hex: "fbbf24"))

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                spacing: 8
            ) {
                ForEach(0..<9, id: \.self) { id in
                    calibDot(id: id, geo: geo)
                }
            }
            .padding(.horizontal, geo.size.width * 0.04)

            Button(action: saveCalibPoint) {
                VStack(spacing: 4) {
                    Text("Kaydet").font(.system(size: geo.size.width * 0.05, weight: .bold))
                    Text(activePtId != nil ? calibLabels[activePtId!] : "Önce nokta seç")
                        .font(.system(size: geo.size.width * 0.03))
                }
                .foregroundColor(activePtId != nil ? .white : Color(hex: "666666"))
                .frame(maxWidth: .infinity)
                .frame(height: geo.size.height * 0.12)
                .background(activePtId != nil ? Color.redAccent : Color(hex: "333333"))
                .cornerRadius(20)
            }
            .disabled(activePtId == nil)
            .padding(.horizontal, geo.size.width * 0.04)

            Button(action: {
                engine.calibration.reset()
                activePtId = nil
            }) {
                Text("Kalibrasyonu Sıfırla")
                    .font(.system(size: geo.size.width * 0.032))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, geo.size.height * 0.015)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.4)))
            }
            .padding(.horizontal, geo.size.width * 0.04)

            Spacer()
        }
    }

    private func calibDot(id: Int, geo: GeometryProxy) -> some View {
        let isSaved  = engine.calibration.points.contains { $0.id == id }
        let isActive = activePtId == id
        let parts    = calibLabels[id].components(separatedBy: " ")

        return Button(action: { activePtId = id }) {
            VStack(spacing: 3) {
                Text(parts.first ?? "").font(.system(size: geo.size.width * 0.03, weight: .semibold))
                Text(parts.dropFirst().joined(separator: " ")).font(.system(size: geo.size.width * 0.025))
                if isSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: geo.size.width * 0.035))
                }
            }
            .foregroundColor(isActive ? .redAccent : isSaved ? .greenOk : .gray)
            .frame(maxWidth: .infinity)
            .frame(height: geo.size.height * 0.1)
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
