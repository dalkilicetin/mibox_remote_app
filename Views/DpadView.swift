import SwiftUI

struct DpadView: View {
    let atv: AtvRemoteService

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let btnSize  = min(w * 0.16, 72.0)   // d-pad buton boyutu
            let pad      = w * 0.05               // yatay padding

            ScrollView {
                VStack(spacing: h * 0.025) {

                    // APK info banner
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.gray)
                            .font(.system(size: w * 0.035))
                        Text("AirCursor APK kurulu değil. Cursor ve dokunmatik pad için APK'yı TV'ye kurun.")
                            .font(.system(size: w * 0.032))
                            .foregroundColor(.gray)
                    }
                    .padding(w * 0.03)
                    .background(Color.blueDeep)
                    .cornerRadius(10)
                    .padding(.horizontal, pad)

                    // Volume
                    HStack(spacing: w * 0.05) {
                        dBtn(icon: "speaker.minus", size: btnSize) { atv.sendKey(AtvKey.volumeDown) }
                        dBtn(icon: "speaker.plus",  size: btnSize) { atv.sendKey(AtvKey.volumeUp) }
                    }

                    // D-Pad
                    VStack(spacing: btnSize * 0.12) {
                        dBtn(icon: "chevron.up",    size: btnSize) { atv.sendKey(AtvKey.dpadUp) }
                        HStack(spacing: btnSize * 0.12) {
                            dBtn(icon: "chevron.left",  size: btnSize) { atv.sendKey(AtvKey.dpadLeft) }
                            centerBtn(size: btnSize * 1.05)
                            dBtn(icon: "chevron.right", size: btnSize) { atv.sendKey(AtvKey.dpadRight) }
                        }
                        dBtn(icon: "chevron.down",  size: btnSize) { atv.sendKey(AtvKey.dpadDown) }
                    }

                    // Action row
                    HStack(spacing: w * 0.04) {
                        labelBtn(icon: "arrow.backward", label: "Geri", w: w) { atv.sendKey(AtvKey.back) }
                        labelBtn(icon: "house",          label: "Home", w: w) { atv.sendKey(AtvKey.home) }
                        labelBtn(icon: "play.fill",      label: "Play", w: w) { atv.sendKey(AtvKey.playPause) }
                    }
                    .padding(.horizontal, pad)
                }
                .padding(.vertical, h * 0.04)
            }
            .background(Color.appBg)
        }
    }

    private func centerBtn(size: CGFloat) -> some View {
        Button(action: {
            atv.sendKey(AtvKey.dpadCenter)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }) {
            Circle().fill(Color.redAccent).frame(width: size, height: size)
                .overlay(Circle().fill(Color.white.opacity(0.2)).frame(width: size * 0.3, height: size * 0.3))
        }
    }

    private func dBtn(icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: { action(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }) {
            Image(systemName: icon)
                .font(.system(size: size * 0.35))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(Color.blueDark)
                .overlay(RoundedRectangle(cornerRadius: size * 0.18).stroke(Color.blueDeep))
                .cornerRadius(size * 0.18)
        }
    }

    private func labelBtn(icon: String, label: String, w: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: { action(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: w * 0.05)).foregroundColor(.white)
                Text(label).font(.system(size: w * 0.028)).foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity).frame(height: w * 0.16)
            .background(Color.blueDark)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blueDeep))
            .cornerRadius(12)
        }
    }
}
