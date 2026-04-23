import SwiftUI

struct KeyboardPopup: View {
    @Binding var text: String
    @Binding var isVisible: Bool
    let onSend: () -> Void
    let onBackspace: () -> Void
    let onEnter: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.5).ignoresSafeArea()
                .onTapGesture { isVisible = false }

            VStack(spacing: 12) {
                Text("TV Klavyesi").font(.subheadline).foregroundColor(.gray)

                TextField("Yazmak istediğinizi girin...", text: $text)
                    .font(.system(size: 16)).foregroundColor(.white)
                    .padding()
                    .background(Color(hex: "0d1117"))
                    .cornerRadius(14)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.redAccent))
                    .autocorrectionDisabled()

                HStack(spacing: 8) {
                    Button(action: onSend) {
                        Text("Gönder").font(.headline).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.redAccent).cornerRadius(14)
                    }
                    Button(action: onBackspace) {
                        Image(systemName: "delete.backward").foregroundColor(.white).font(.system(size: 18))
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blueDeep))
                    }
                    Button(action: onEnter) {
                        Image(systemName: "return").foregroundColor(.greenOk).font(.system(size: 18))
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.greenOk))
                    }
                }

                Button("Kapat") { isVisible = false }.foregroundColor(.gray)
            }
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 32)
            .background(
                Color.cardBg
                    .cornerRadius(24, corners: [.topLeft, .topRight])
                    .overlay(RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.blueDeep, lineWidth: 2)
                        .padding(.bottom, -24))
            )
        }
        .ignoresSafeArea(.keyboard)
    }
}
