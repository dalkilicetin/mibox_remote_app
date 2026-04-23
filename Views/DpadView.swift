import SwiftUI

struct DpadView: View {
    let atv: AtvRemoteService

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // Buton boyutu: ekranın küçük boyutuna göre ölçekle
            let btnSize = min(w * 0.17, h * 0.11, 72.0)
            let sp = h * 0.02   // spacing

            VStack(spacing: sp) {
                Spacer(minLength: 0)

                // APK info banner
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.gray)
                        .font(.system(size: w * 0.033))
                    Text("AirCursor APK yok — cursor ve touchpad için TV'ye kurun.")
                        .font(.system(size: w * 0.03))
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, w * 0.03)
                .padding(.vertical, h * 0.012)
                .background(Color.blueDeep)
                .cornerRadius(10)
                .padding(.horizontal, w * 0.04)

                // Volume
                HStack(spacing: w * 0.08) {
                    dBtn(icon: "speaker.minus", size: btnSize) { atv.sendKey(AtvKey.volumeDown) }
                    dBtn(icon: "speaker.plus",  size: btnSize) { atv.sendKey(AtvKey.volumeUp) }
                }

                // D-Pad
                VStack(spacing: btnSize * 0.15) {
                    dBtn(icon: "chevron.up",    size: btnSize) { atv.sendKey(AtvKey.dpadUp) }
                    HStack(spacing: btnSize * 0.15) {
                        dBtn(icon: "chevron.left",  size: btnSize) { atv.sendKey(AtvKey.dpadLeft) }
                        centerBtn(size: btnSize * 1.1)
                        dBtn(icon: "chevron.right", size: btnSize) { atv.sendKey(AtvKey.dpadRight) }
                    }
                    dBtn(icon: "chevron.down",  size: btnSize) { atv.sendKey(AtvKey.dpadDown) }
                }

                // Action row
                HStack(spacing: w * 0.03) {
                    labelBtn(icon: "arrow.backward", label: "Geri", w: w, h: h) { atv.sendKey(AtvKey.back) }
                    labelBtn(icon: "house",          label: "Home", w: w, h: h) { atv.sendKey(AtvKey.home) }
                    labelBtn(icon: "play.fill",      label: "Play", w: w, h: h) { atv.sendKey(AtvKey.playPause) }
                }
                .padding(.horizontal, w * 0.04)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appBg)
        }
    }

    private func centerBtn(size: CGFloat) -> some View {
        Button(action: {
            atv.sendKey(AtvKey.dpadCenter)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }) {
            Circle().fill(Color.redAccent).frame(width: size, height: size)
                .overlay(Circle().fill(Color.white.opacity(0.15)).frame(width: size * 0.3, height: size * 0.3))
        }
    }

    private func dBtn(icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: { action(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }) {
            Image(systemName: icon)
                .font(.system(size: size * 0.38))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(Color.blueDark)
                .overlay(RoundedRectangle(cornerRadius: size * 0.2).stroke(Color.blueDeep))
                .cornerRadius(size * 0.2)
        }
    }

    private func labelBtn(icon: String, label: String, w: CGFloat, h: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: { action(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: w * 0.048)).foregroundColor(.white)
                Text(label).font(.system(size: w * 0.027)).foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity)
            .frame(height: h * 0.09)
            .background(Color.blueDark)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blueDeep))
            .cornerRadius(12)
        }
    }
}

// CGFloat üçlü min helper
private func min(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat) -> CGFloat {
    Swift.min(a, Swift.min(b, c))
}
