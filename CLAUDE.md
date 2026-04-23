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

## Konuşma Notları

<!-- Önemli kararlar ve değişiklik talepleri buraya eklenir -->

### [2026-04-23]
- Proje ilk kez okundu ve anlaşıldı.
- Kullanıcı değişiklik isteyecek.
