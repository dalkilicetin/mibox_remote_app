# mibox_remote_app — Proje Notları

Bu dosya, Claude ile yapılan konuşmalarda alınan kararları, bağlamı ve önemli notları kalıcı olarak saklar.

---

## Proje Genel Bakış

**Mi Box Remote** — Xiaomi Mi Box (Android TV) cihazlarını akıllı telefondan kontrol etmeye yarayan Flutter uygulaması.

- Platform: iOS, Android, Web, Linux, macOS, Windows
- Dil: Dart 3.0+, UI Türkçe
- Branch: `main`

---

## Proje Yapısı

```
lib/
├── main.dart                  # Giriş noktası, tema, SetupScreen router
├── screens/
│   ├── setup_screen.dart      # Cihaz keşfi, eşleşme, manuel IP girişi
│   ├── remote_screen.dart     # Ana kontrol merkezi (tab navigasyon)
│   ├── air_mouse_screen.dart  # Jiroskop tabanlı hava faresi
│   └── touchpad_screen.dart   # Dokunmatik touchpad + kaydırma
├── services/
│   ├── mibox_service.dart     # AirCursor APK protokolü (UDP/TCP, JSON)
│   ├── atv_remote_service.dart# Android TV Remote v2 (TLS + Protobuf)
│   └── atv_service.dart       # ADB wrapper (kullanılmıyor/eski)
└── widgets/                   # (boş)
```

---

## Mimari

- **State yönetimi:** Saf StatefulWidget + Stream (BLoC/Provider yok)
- **Kalıcı depolama:** SharedPreferences (IP, port) + FlutterSecureStorage (TLS sertifikaları)
- **İki paralel protokol:**
  - **APK Protokolü:** UDP keşif (9877) + JSON/TCP komut (9876) — hızlı, cursor destekli
  - **ATV Remote v2:** TLS/Protobuf (6466) — resmi protokol, her TV'de çalışır

---

## Ekranlar & Akış

```
SetupScreen → (eşleşme varsa) RemoteScreen
                (eşleşme yoksa) PairingScreen → RemoteScreen

RemoteScreen Tabları:
  Tab 0: AirMouseScreen  (APK varsa)
  Tab 1: TouchpadScreen  (APK varsa) / DpadScreen (APK yoksa)
  Tab 2: DebugScreen     (loglar, yeniden bağlan)
```

---

## Önemli Servisler

| Servis | Protokol | Port | Amaç |
|--------|----------|------|------|
| MiBoxService | UDP+TCP/JSON | 9876/9877 | APK cursor kontrolü |
| AtvRemoteService | TLS+Protobuf | 6466 | TV tuş kontrolü |
| _AtvPairingSession | TLS+Protobuf | 6467 | RSA eşleşme |

---

## Kullanılan Paketler

- `sensors_plus` — ivmeölçer, manyetometre
- `shared_preferences` — IP/port kaydetme
- `flutter_secure_storage` — sertifika saklama
- `pointycastle` + `basic_utils` + `asn1lib` — RSA, X.509, kriptografi
- `nsd` — mDNS cihaz keşfi
- `permission_handler` — Android/iOS izinleri

---

## Cihaz Keşif Stratejisi

1. mDNS (`_androidtvremote._tcp`) — hızlı, nazik
2. UDP broadcast (AirCursor APK keşfi)
3. TCP port taraması (/24 subnet) — yedek, agresif

---

## Swift iOS Projesi (Aktif)

Flutter'dan Swift'e geçildi. Gerekçe: Flutter'da dart:io SecureSocket ile ATV Remote v2 TLS/sertifika protokolü düzgün çalışmıyor.

**Proje konumu:** `swift_app/`

**Build:** GitHub Actions macOS runner → XcodeGen → xcodebuild (workflow: `.github/workflows/ios_swift_build.yml`)

### Swift Proje Yapısı

```
swift_app/
├── project.yml                          # XcodeGen config
└── MiBoxRemote/
    ├── App/MiBoxRemoteApp.swift          # @main entry
    ├── Models/DiscoveredDevice.swift
    ├── Services/
    │   ├── MiBoxService.swift            # APK TCP/JSON (port 9876, UDP 9877)
    │   ├── AtvRemoteService.swift        # ATV Remote v2 TLS/Protobuf (port 6466)
    │   ├── PairingService.swift          # ATV pairing TLS (port 6467)
    │   └── DeviceDiscovery.swift         # mDNS + UDP + TCP sweep
    ├── Utilities/
    │   ├── DEREncoder.swift              # ASN.1/DER builder (self-signed cert için)
    │   ├── DERParser.swift               # PKCS#1 RSA modulus/exponent parser
    │   ├── ProtoWriter.swift             # Protobuf varint encoder
    │   ├── KeychainHelper.swift          # SecIdentity, UserDefaults wrapper
    │   ├── CertificateHelper.swift       # RSA keygen + self-signed X.509
    │   └── AppColors.swift               # Color constants, AtvKey constants
    └── Views/
        ├── SetupView.swift               # Cihaz keşfi + liste
        ├── PairingView.swift             # TLS pairing + PIN
        ├── RemoteView.swift              # Tab container + ATV init
        ├── AirMouseView.swift            # Jiroskop + sensor fusion
        ├── TouchpadView.swift            # Multi-touch (UIKit wrapper)
        ├── DpadView.swift                # APK yoksa basit d-pad
        ├── DebugView.swift               # Log görüntüleyici
        └── KeyboardPopup.swift           # TV klavye bottom sheet
```

### Kritik Teknik Kararlar

- **TLS:** `Network.framework` NWConnection, `sec_protocol_options_set_local_identity` ile client cert
- **Sertifika:** `Security.framework` SecKeyCreateRandomKey (RSA 2048) + manuel DER encoder ile self-signed X.509, `SecCertificateCreateWithData`
- **PIN hash:** `CryptoKit` SHA256 (clientMod + clientExp + serverMod + serverExp + pinHashPart)
- **Keychain:** SecIdentity = SecCertificate + SecKey aynı label ile store edilince iOS otomatik link eder
- **Multi-touch:** UIViewRepresentable wrapper (SwiftUI DragGesture pointer count vermiyor)
- **Sensor fusion:** CMMotionManager (accelerometer=pitch, magnetometer=yaw), LP=0.5

### Konuşma Notları

### [2026-04-23]
- Flutter projesinin tüm requirementları çıkarıldı (detaylı liste CLAUDE.md'de)
- Swift iOS projesinin tüm dosyaları yazıldı
- Kullanıcı Mac'siz, Windows + GitHub Actions workflow ile build yapıyor
- Flutter projesi `mibox_remote_app/` klasöründe duruyor (silinmedi)
