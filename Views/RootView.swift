import SwiftUI

// MARK: - Screen state machine
// Tüm navigation buradan yönetilir — NavigationStack/fullScreenCover yok

enum Screen {
    case setup
    case pairing(DiscoveredDevice)
    case remote(DiscoveredDevice)
}

struct RootView: View {
    @State private var screen: Screen = .setup

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            switch screen {
            case .setup:
                SetupView(
                    onRemote:  { device in screen = .remote(device) },
                    onPairing: { device in screen = .pairing(device) }
                )

            case .pairing(let device):
                PairingView(device: device) { success, newCertKey in
                    if success {
                        var updated = device
                        if let key = newCertKey, !key.isEmpty, key != device.ip {
                            updated.mac = key
                        }
                        KeychainHelper.saveStr(updated.certKey, key: "mibox_certkey")
                        screen = .remote(updated)
                    } else {
                        screen = .setup
                    }
                }

            case .remote(let device):
                RemoteView(
                    device: device,
                    apkService: nil,
                    onDismiss:    { screen = .setup },
                    onNeedPairing: { screen = .pairing(device) }
                )
            }
        }
        .ignoresSafeArea(edges: .bottom)   // sadece alt — status bar korunur
        .preferredColorScheme(.dark)
    }
}
