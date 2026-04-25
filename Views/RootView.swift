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
            Color.green.opacity(0.3).ignoresSafeArea()   // DEBUG ROOT

            switch screen {
            case .setup:
                SetupView(
                    onRemote:  { device in screen = .remote(device) },
                    onPairing: { device in screen = .pairing(device) }
                )
                .background(Color.red.opacity(0.3))   // DEBUG L1

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
                .background(Color.blue.opacity(0.3))   // DEBUG L1

            case .remote(let device):
                RemoteView(
                    device: device,
                    apkService: nil,
                    onDismiss:    { screen = .setup },
                    onNeedPairing: { screen = .pairing(device) }
                )
                .background(Color.yellow.opacity(0.3))   // DEBUG L1
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}
