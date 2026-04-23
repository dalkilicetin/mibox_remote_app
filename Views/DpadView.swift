import SwiftUI

struct DpadView: View {
    let atv: AtvRemoteService

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // APK warning
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundColor(.gray).font(.system(size: 14))
                    Text("AirCursor APK kurulu değil. Cursor ve dokunmatik pad için APK'yı TV'ye kurun.")
                        .font(.system(size: 12)).foregroundColor(.gray)
                }
                .padding(12)
                .background(Color.blueDeep).cornerRadius(10)
                .padding(.horizontal, 20)

                // Volume
                HStack(spacing: 16) {
                    dBtn(icon: "speaker.minus") { atv.sendKey(AtvKey.volumeDown) }
                    dBtn(icon: "speaker.plus")  { atv.sendKey(AtvKey.volumeUp) }
                }

                // D-Pad
                VStack(spacing: 8) {
                    dBtn(icon: "chevron.up")   { atv.sendKey(AtvKey.dpadUp) }
                    HStack(spacing: 8) {
                        dBtn(icon: "chevron.left")  { atv.sendKey(AtvKey.dpadLeft) }
                        centerBtn
                        dBtn(icon: "chevron.right") { atv.sendKey(AtvKey.dpadRight) }
                    }
                    dBtn(icon: "chevron.down") { atv.sendKey(AtvKey.dpadDown) }
                }

                // Action row
                HStack(spacing: 16) {
                    labelBtn(icon: "arrow.backward", label: "Geri") { atv.sendKey(AtvKey.back) }
                    labelBtn(icon: "house",          label: "Home") { atv.sendKey(AtvKey.home) }
                    labelBtn(icon: "play.fill",      label: "Play") { atv.sendKey(AtvKey.playPause) }
                }
            }
            .padding(.vertical, 32)
        }
        .background(Color.appBg)
    }

    private var centerBtn: some View {
        Button(action: { atv.sendKey(AtvKey.dpadCenter); UIImpactFeedbackGenerator(style: .medium).impactOccurred() }) {
            Circle().fill(Color.redAccent).frame(width: 64, height: 64)
                .overlay(Circle().fill(Color.white.opacity(0.2)).frame(width: 20, height: 20))
        }
    }

    private func dBtn(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }) {
            Image(systemName: icon).font(.system(size: 22)).foregroundColor(.white)
                .frame(width: 64, height: 64)
                .background(Color.blueDark)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blueDeep))
                .cornerRadius(12)
        }
    }

    private func labelBtn(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: { action(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18)).foregroundColor(.white)
                Text(label).font(.system(size: 9)).foregroundColor(.gray)
            }
            .frame(width: 80, height: 64)
            .background(Color.blueDark)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blueDeep))
            .cornerRadius(12)
        }
    }
}
