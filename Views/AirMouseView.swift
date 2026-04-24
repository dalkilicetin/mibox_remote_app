import SwiftUI
import CoreMotion

struct AirMouseView: View {
    let apk: MiBoxService
    let atv: AtvRemoteService

    @State private var airOn     = false
    @State private var debugText = "Hazır"
    @State private var sensitivity: Double = 25
    @State private var kbdVisible = false
    @State private var kbdText   = ""
    @State private var swipeCooldown = false

    // Filter state
    @State private var fbeta = 0.0
    @State private var filterInit = false
    @State private var lastRawAlpha = 0.0
    @State private var filteredDa   = 0.0
    @State private var lastAlphaInit = false
    @State private var lastBeta  = 0.0
    @State private var lastTime  = Date()
    @State private var rawAlpha  = 0.0
    @State private var rawBeta   = 0.0

    // Tap tracking
    @State private var tapStart  = CGPoint.zero
    @State private var tapLast   = CGPoint.zero
    @State private var tapTime   = Date()
    @State private var tapAccumV = 0.0
    @State private var tapAccumH = 0.0
    @State private var swipeAccum = 0.0

    private let motion = CMMotionManager()
    // NOT: CMMotionManager `let` olarak tanımlı ama class olduğu için referans tutulur.
    // SwiftUI struct yeniden oluşturulsa da aynı instance kullanılmaya devam eder
    // çünkü SwiftUI property storage'ı korur.
    private static let LP = 0.5
    private static let TAP_MAX_MOVE: Double = 12
    private static let TAP_MAX_MS   = 250
    private static let SCROLL_THRESH: Double = 65
    private static let SWIPE_THRESH:  Double = 40

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    debugBar(geo: geo)
                    toggleButton(geo: geo)
                    mainArea(geo: geo)
                    actionButtons(geo: geo)
                    keyboardButton(geo: geo)
                    sensitivitySlider(geo: geo)
                }
                if kbdVisible {
                    KeyboardPopup(text: $kbdText, isVisible: $kbdVisible,
                                  onSend: sendText,
                                  onBackspace: { apk.sendKey(67) },
                                  onEnter: { apk.sendKey(66) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appBg)
            .onAppear  { startSensors() }
            .onDisappear { stopSensors() }
        }
    }

    // MARK: - Sub-views

    private func debugBar(geo: GeometryProxy) -> some View {
        let sensorStatus = motion.isAccelerometerActive ? "ACC✓" : "ACC✗"
        let magStatus = motion.isMagnetometerActive ? "MAG✓" : "MAG✗"
        return Text("\(sensorStatus) \(magStatus) | \(debugText)")
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
                        tapTime  = Date(); tapAccumV = 0; tapAccumH = 0
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
                        if airOn { apk.tap(); if atv.isConnected { atv.sendKey(AtvKey.dpadCenter) } }
                        else { sendKey(AtvKey.dpadCenter) }
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
        .gesture(DragGesture().onChanged { v in
            swipeAccum += v.translation.height
            if abs(swipeAccum) >= Self.SWIPE_THRESH {
                sendSwipe(swipeAccum > 0 ? -1 : 1); swipeAccum = 0
            }
        }.onEnded { _ in swipeAccum = 0 })
    }

    private func actionButtons(geo: GeometryProxy) -> some View {
        VStack(spacing: geo.size.height * 0.008) {
            HStack(spacing: geo.size.width * 0.02) {
                airBtn(icon: "arrow.backward", label: "Geri",  geo: geo) { sendKey(AtvKey.back) }
                airBtn(icon: "house",          label: "Home",  geo: geo) { sendKey(AtvKey.home) }
            }
            HStack(spacing: geo.size.width * 0.02) {
                airBtn(icon: "speaker.plus",   label: "Ses+",  geo: geo) { sendKey(AtvKey.volumeUp) }
                airBtn(icon: "speaker.minus",  label: "Ses-",  geo: geo) { sendKey(AtvKey.volumeDown) }
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
                    .font(.system(size: geo.size.width * 0.03))
                    .foregroundColor(.gray)
                Spacer()
                Text("\(Int(sensitivity))")
                    .font(.system(size: geo.size.width * 0.03, weight: .bold))
                    .foregroundColor(.redAccent)
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

    // MARK: - Sensors

    private func startSensors() {
        // Önceki oturumdan kalan updates'i temizle
        motion.stopAccelerometerUpdates()
        motion.stopMagnetometerUpdates()
        // Filter state'i sıfırla — eski değerlerle cursor zıplamasın
        filterInit = false; lastAlphaInit = false; filteredDa = 0

        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 1.0/60
            motion.startAccelerometerUpdates(to: .main) { data, _ in
                guard let d = data else { return }
                rawBeta = atan2(d.acceleration.y, sqrt(d.acceleration.x*d.acceleration.x + d.acceleration.z*d.acceleration.z)) * 180 / .pi
                onGyro()
            }
        }
        if motion.isMagnetometerAvailable {
            motion.magnetometerUpdateInterval = 1.0/60
            motion.startMagnetometerUpdates(to: .main) { data, _ in
                guard let d = data else { return }
                var a = atan2(d.magneticField.y, d.magneticField.x) * 180 / .pi
                if a < 0 { a += 360 }
                rawAlpha = a
            }
        }
    }

    private func stopSensors() {
        motion.stopAccelerometerUpdates()
        motion.stopMagnetometerUpdates()
    }

    private func onGyro() {
        if !filterInit { fbeta = rawBeta; filterInit = true }
        fbeta = Self.LP * rawBeta + (1 - Self.LP) * fbeta

        if !airOn {
            debugText = "pitch:\(String(format:"%.1f",fbeta)) yaw:\(String(format:"%.1f",rawAlpha))"
            lastBeta = fbeta; lastRawAlpha = rawAlpha; lastAlphaInit = true
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastTime) * 1000 >= 16, lastAlphaInit else {
            lastBeta = fbeta; lastRawAlpha = rawAlpha; lastAlphaInit = true; return
        }

        var db = fbeta - lastBeta
        if db > 90 { db -= 180 }; if db < -90 { db += 180 }

        var rawDa = lastRawAlpha - rawAlpha
        if rawDa > 180 { rawDa -= 360 }; if rawDa < -180 { rawDa += 360 }
        filteredDa = Self.LP * rawDa + (1 - Self.LP) * filteredDa
        var da = filteredDa

        if abs(db) < 0.3 { db = 0 }
        if abs(da) < 0.05 { da = 0 }

        if db != 0 || da != 0 {
            let speed = sqrt(db*db + da*da)
            let boost = speed > 3 ? 1.0 + (speed - 3) * 0.3 : 1.0
            let dx = Int((da * boost * 25).rounded())
            let dy = Int((db * sensitivity/25 * boost * -25).rounded())
            if dx != 0 || dy != 0 { apk.moveCursor(dx: dx, dy: dy) }
            debugText = "pitch:\(String(format:"%.2f",db)) yaw:\(String(format:"%.2f",da))"
        }

        lastBeta = fbeta; lastRawAlpha = rawAlpha; lastAlphaInit = true; lastTime = now
    }

    // MARK: - Actions

    private func toggleAir() {
        airOn.toggle()
        filterInit = false; lastAlphaInit = false; filteredDa = 0
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
