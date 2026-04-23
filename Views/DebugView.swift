import SwiftUI

struct DebugView: View {
    @Binding var logs: [String]
    let onClear: () -> Void
    let onReconnect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onReconnect) {
                    Label("Yeniden Bağlan", systemImage: "arrow.clockwise")
                        .foregroundColor(.redAccent).font(.system(size: 12))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.redAccent))
                }
                Button(action: onClear) {
                    Text("Temizle").foregroundColor(.gray).font(.system(size: 12))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray))
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            if logs.isEmpty {
                Spacer()
                Text("Log yok").foregroundColor(.gray)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logs.reversed().enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(color(for: line))
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
        .background(Color.appBg)
    }

    private func color(for line: String) -> Color {
        if line.contains("HATA") || line.contains("KESİLDİ") || line.contains("error") || line.contains("başarısız") { return .red }
        if line.contains("✓") || line.contains("BAĞLANDI") || line.contains("hash") { return .greenOk }
        if line.contains("→") || line.contains("←") { return .blueInfo }
        return .gray
    }
}
