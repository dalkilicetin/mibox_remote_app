import SwiftUI
import UIKit

struct TouchpadView: View {
    let apk: MiBoxService
    let atv: AtvRemoteService

    @State private var kbdVisible = false
    @State private var kbdText    = ""
    @State private var swipeAccum = 0.0
    @State private var swipeCooldown = false

    var body: some View {
        ZStack {
            VStack(spacing: 6) {
                touchpadArea
                hScrollBar
                clickButton
                keyboardButton
                actionButtons
                Spacer(minLength: 8)
            }
            if kbdVisible {
                KeyboardPopup(text: $kbdText, isVisible: $kbdVisible,
                              onSend: sendText, onBackspace: { apk.sendKey(67) }, onEnter: { apk.sendKey(66) })
            }
        }
        .background(Color.appBg)
    }

    // MARK: - Touchpad (UIKit wrapper for multi-touch)

    private var touchpadArea: some View {
        HStack(spacing: 0) {
            TouchpadRepresentable(apk: apk, atv: atv)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(hex: "0d1117"))
                .cornerRadius(16, corners: [.topLeft, .bottomLeft])

            dpadScrollBar

            Spacer().frame(width: 8)

            swipeScrollBar
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 12).padding(.top, 8)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blueDeep, lineWidth: 2).padding(.horizontal, 12).padding(.top, 8))
    }

    private var dpadScrollBar: some View {
        VStack(spacing: 0) {
            Button(action: { sendKey(AtvKey.dpadUp) }) {
                Image(systemName: "chevron.up").foregroundColor(.gray).padding(8)
            }
            Rectangle().fill(Color.blueDeep).frame(width: 4, height: 40)
            Button(action: { sendKey(AtvKey.dpadDown) }) {
                Image(systemName: "chevron.down").foregroundColor(.gray).padding(8)
            }
        }
        .frame(width: 36)
        .background(Color(hex: "0d1117"))
    }

    private var swipeScrollBar: some View {
        VStack(spacing: 0) {
            Button(action: { sendSwipe(1) }) {
                Image(systemName: "chevron.up").foregroundColor(.greenOk).padding(6)
            }
            Text("S").font(.system(size: 9)).foregroundColor(.greenOk)
            Rectangle().fill(Color.greenOk).frame(width: 4, height: 30)
            Text("W").font(.system(size: 9)).foregroundColor(.greenOk)
            Button(action: { sendSwipe(-1) }) {
                Image(systemName: "chevron.down").foregroundColor(.greenOk).padding(6)
            }
        }
        .frame(width: 36)
        .background(Color(hex: "0d1117"))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.greenOk, lineWidth: 2))
        .cornerRadius(16)
        .gesture(DragGesture().onChanged { v in
            swipeAccum += v.translation.height
            if abs(swipeAccum) >= 40 { sendSwipe(swipeAccum > 0 ? -1 : 1); swipeAccum = 0 }
        }.onEnded { _ in swipeAccum = 0 })
    }

    private var hScrollBar: some View {
        HStack {
            Button(action: { sendKey(AtvKey.dpadLeft) }) {
                Image(systemName: "chevron.left").foregroundColor(.gray).padding(.horizontal, 8)
            }
            Spacer()
            Rectangle().fill(Color.blueDeep).frame(width: 60, height: 4)
            Spacer()
            Button(action: { sendKey(AtvKey.dpadRight) }) {
                Image(systemName: "chevron.right").foregroundColor(.gray).padding(.horizontal, 8)
            }
        }
        .frame(height: 36)
        .background(Color(hex: "0d1117"))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blueDeep, lineWidth: 2))
        .cornerRadius(16)
        .padding(.horizontal, 12)
    }

    private var clickButton: some View {
        Button(action: {
            apk.tap()
            if atv.isConnected { atv.sendKey(AtvKey.dpadCenter) }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.click").foregroundColor(.greenOk)
                Text("Tikla").foregroundColor(.greenOk).font(.system(size: 15))
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(Color(hex: "1a3a1a"))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.greenOk))
            .cornerRadius(12)
        }
        .padding(.horizontal, 12)
    }

    private var keyboardButton: some View {
        Button(action: { kbdVisible = true }) {
            Label("Klavye", systemImage: "keyboard").foregroundColor(.greenOk)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.greenOk))
        }
        .padding(.horizontal, 12)
    }

    private var actionButtons: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                tpBtn(icon: "arrow.backward", label: "Geri")  { sendKey(AtvKey.back) }
                tpBtn(icon: "house",          label: "Home")  { sendKey(AtvKey.home) }
                tpBtn(icon: "play.fill",      label: "Play")  { sendKey(AtvKey.playPause) }
            }
            HStack(spacing: 8) {
                tpBtn(icon: "speaker.plus",   label: "Ses+")  { sendKey(AtvKey.volumeUp) }
                tpBtn(icon: "speaker.minus",  label: "Ses-")  { sendKey(AtvKey.volumeDown) }
            }
        }
        .padding(.horizontal, 12)
    }

    private func tpBtn(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16))
                Text(label).font(.system(size: 12))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(Color.blueDark)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blueDeep))
            .cornerRadius(12)
        }
    }

    private func sendKey(_ code: Int) {
        if atv.isConnected { atv.sendKey(code) } else { apk.sendKey(code) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func sendSwipe(_ dir: Int) {
        guard !swipeCooldown else { return }
        swipeCooldown = true
        let cx = apk.cursorX, cy = apk.cursorY
        let y2 = max(50, min(MiBoxService.screenH - 50, cy - 150 * dir))
        apk.sendSwipe(x1: cx, y1: cy, x2: cx, y2: y2, duration: 100)
        apk.setScrollMode(1)
        Task { try? await Task.sleep(for: .milliseconds(200)); swipeCooldown = false }
    }

    private func sendText() {
        guard !kbdText.isEmpty else { return }
        apk.sendText(kbdText); kbdText = ""
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

// MARK: - UIKit touchpad (multi-touch)

private struct TouchpadRepresentable: UIViewRepresentable {
    let apk: MiBoxService
    let atv: AtvRemoteService

    func makeUIView(context: Context) -> TouchpadUIView {
        let v = TouchpadUIView()
        v.apk = apk; v.atv = atv
        return v
    }
    func updateUIView(_ uiView: TouchpadUIView, context: Context) {
        uiView.apk = apk; uiView.atv = atv
    }
}

final class TouchpadUIView: UIView {
    var apk: MiBoxService!
    var atv: AtvRemoteService!

    private var lastPos: CGPoint?
    private var scrollLastPos: CGPoint?
    private var isScrollMode = false
    private var scrollAccumV = 0.0
    private var scrollAccumH = 0.0
    private var lastTap = Date.distantPast
    private static let SCROLL_THRESH = 60.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = event?.allTouches?.count ?? 1
        if all == 2 {
            isScrollMode = true
            scrollLastPos = centroid(event?.allTouches)
            scrollAccumV = 0; scrollAccumH = 0
        } else {
            isScrollMode = false
            lastPos = touches.first?.location(in: self)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isScrollMode {
            let c = centroid(event?.allTouches) ?? .zero
            let dy = c.y - (scrollLastPos?.y ?? c.y)
            let dx = c.x - (scrollLastPos?.x ?? c.x)
            scrollLastPos = c
            scrollAccumV += dy; scrollAccumH += dx
            if abs(scrollAccumV) >= Self.SCROLL_THRESH {
                sendKey(scrollAccumV > 0 ? 20 : 19)
                apk.setScrollMode(1); scrollAccumV = 0
            }
            if abs(scrollAccumH) >= Self.SCROLL_THRESH {
                sendKey(scrollAccumH > 0 ? 22 : 21)
                apk.setScrollMode(2); scrollAccumH = 0
            }
        } else {
            guard let touch = touches.first, let last = lastPos else { return }
            let cur = touch.location(in: self)
            let dx = Int((cur.x - last.x) * 3)
            let dy = Int((cur.y - last.y) * 3)
            lastPos = cur
            apk.moveCursor(dx: dx, dy: dy)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastPos = nil; scrollLastPos = nil; isScrollMode = false
        // Double-tap detection
        let now = Date()
        if now.timeIntervalSince(lastTap) < 0.3 {
            apk.tap()
            if atv.isConnected { atv.sendKey(23) }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        lastTap = now
    }

    private func centroid(_ touches: Set<UITouch>?) -> CGPoint? {
        guard let touches, !touches.isEmpty else { return nil }
        let sum = touches.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.location(in: self).x, y: $0.y + $1.location(in: self).y)
        }
        return CGPoint(x: sum.x / CGFloat(touches.count), y: sum.y / CGFloat(touches.count))
    }

    private func sendKey(_ code: Int) {
        if atv.isConnected { atv.sendKey(code) } else { apk.sendKey(code) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Corner radius helper

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat; var corners: UIRectCorner
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}
