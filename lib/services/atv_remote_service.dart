import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// AndroidTV Remote Protocol v2 — port 6466, TLS
/// Proto: remotemessage.proto
/// RemoteMessage field 10 = remote_key_inject { key_code, direction }
/// RemoteDirection: SHORT=3, START_LONG=1, END_LONG=2
class AtvRemoteService {
  int _remotePort = 6466;
  SecureSocket? _socket;
  bool _connected = false;
  String _ip = '';
  String _certPem = '';
  String _keyPem  = '';

  Timer? _pingTimer;
  Timer? _reconnectTimer;

  // UI log callback — remote_screen buraya bağlanır
  void Function(String)? onLog;

  void _log(String msg) {
    print('[ATV] $msg');
    onLog?.call(msg);
  }

  final StreamController<bool> _connCtrl = StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connCtrl.stream;
  bool get isConnected => _connected;

  // connect() true döndüğünde remote_screen bunu okusun diye
  // stream race condition'ı önlemek için poll yöntemi de var
  bool get lastConnected => _connected;

  // 4-byte length prefix için buffer
  final List<int> _recvBuf = [];

  void setCertificates(String cert, String key) {
    _certPem = cert;
    _keyPem  = key;
  }

  Future<bool> connect(String ip, {int remotePort = 6466}) async {
    _ip = ip;
    _remotePort = remotePort;
    if (_certPem.isEmpty || _keyPem.isEmpty) {
      _log('Sertifika yok — pairing gerekli');
      return false;
    }
    // TEST: Python'ın ürettiği sertifika — çalışıp çalışmadığını test et
    const _testCert = '''-----BEGIN CERTIFICATE-----
MIIC0DCCAbigAwIBAgICA+gwDQYJKoZIhvcNAQELBQAwFTETMBEGA1UEAwwKVGVz
dFJlbW90ZTAeFw0yNjA0MTgxNjM0MTBaFw0zNjA0MTUxNjM0MTBaMBUxEzARBgNV
BAMMClRlc3RSZW1vdGUwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCL
W9aA9g4mRn1sAEyQQeroteINgNNBJl9BCfZ8sB5+3/B3wiOn8fM7Kq5QK7kelSFH
UZc4D1PRMdnFvXGlHfvyiDVud5pU1BP9N6ProFC+SsU7OcHeF19VMjdBReHvXE0A
/wUOPivfRSetZPILJefUbAkjF2fF4CVixTIMY+zFVwAkLZmkXiNuFHlOvlXo9QHt
4geD86iZt1kmfOJtNdee+2l6uORl3fZaXn8e581Yg82l5zk9w65aTEjC1mW5CZLc
cGwkCFEWNTc24++j4srjm7YsZ3ZUvcWhHMF5MnMV/CNH2TNdiPKi6lVTudDNGgkw
pAA96G8/fLk9jxXCmAIRAgMBAAGjKjAoMA8GA1UdEwQIMAYBAf8CAQAwFQYDVR0R
BA4wDIIKVGVzdFJlbW90ZTANBgkqhkiG9w0BAQsFAAOCAQEAgFQUYNVxq55rRRV5
6MsnE9ItOO6gIisnCHNTKCTXQnNVWCGTJRy8xq3267DIDAZ5h7st9ETiw6oLBKSX
VQrAHYu5vMUlmGRoWEo74bSC6LFH7JT1VWRrnrJIcX48JnEwk9T4jgtX8+FNRcih
KdM01s5wLBEy1nf9PYR1s+o0eWZn08A5WNtEeVYaEdhXe8DecyKbdlPohVWYhgL6
+vbuCSuk9etIfwyat7+PUB4kbXauYmR9xH/IkjMrhx6e7+dluUtAO8sAL2CApxSq
DJ7Y/p865fcPgcS0LVEdUOVPReQZZNadQHpcS+NKjpfhDHxsKBjkRlGRG/DME1yg
Jcik2w==
-----END CERTIFICATE-----''';
    const _testKey = '''-----BEGIN RSA PRIVATE KEY-----
MIIEogIBAAKCAQEAi1vWgPYOJkZ9bABMkEHq6LXiDYDTQSZfQQn2fLAeft/wd8Ij
p/HzOyquUCu5HpUhR1GXOA9T0THZxb1xpR378og1bneaVNQT/Tej66BQvkrFOznB
3hdfVTI3QUXh71xNAP8FDj4r30UnrWTyCyXn1GwJIxdnxeAlYsUyDGPsxVcAJC2Z
pF4jbhR5Tr5V6PUB7eIHg/OombdZJnzibTXXnvtperjkZd32Wl5/HufNWIPNpec5
PcOuWkxIwtZluQmS3HBsJAhRFjU3NuPvo+LK45u2LGd2VL3FoRzBeTJzFfwjR9kz
XYjyoupVU7nQzRoJMKQAPehvP3y5PY8VwpgCEQIDAQABAoIBAArAVqkY3T3CivBp
3n5I+PFOqkZd6w5tQi808FAC0Lt7leRQtT+tTiqr+opDW/MPe3jdLdQx9Ia2DfBw
PY6zpJQmbNmH/yoDuZi7x0Oerj6xazbMQtgaSAJ9ObTpX2AAKDhcibHlWyz3Zh39
uiG2NoTqzSf9/oV41ebhQqD2QED3fey9uF2+i/e+U5xOT0Yg+rtWtiaxwWgjEP2s
teVczUtyLitL2XCKCA64mqryeXmJEWD6MbKiRWa0LsNa3YXeZFV2jYe4q41I47nf
Cn9pNMXRSnJi2LDJzrGb+ln51wglZCQEa0VPtTa2x+08Du/+Ui/RKyXXD3Cm9EnU
FLewMHUCgYEAv9jXL3Y4nek/DAgcHO7upUu50l6JDA3Gs47BNzyiXU+eD+31hQrZ
aWE5Kqog62tdEU3ggtesUa3XccMKjhvglvjxEAcDNoDM/6iHvyCjx36B8zyNt1tx
cfVjd0PbKRcP+RTNnXgfsHhmvzgV0v4smn7lUFxWV46R5noruabBx6UCgYEAufW2
HMYoK0PiFoppuLhkkeQFBNGBx2y/cEth4tKABu++NinW/j2MEitReEaX3bxuwo1s
KFv1Ph5T8pIYaZ3UwF6bUDNwlyDPAPljE/ABlUGc3kgtEM0UXvDOiUb0mSn58X8A
xPn9bpUyMUCXETxZ9RTsbkDKZv7XV2WCnUVwpP0CgYBzN0gsoeRouc76a9hua/R4
4xyrQckuqwtdhOt3P/wG7CzyRigAib5+cjxB6kCxAh63qLyf9+TufOf503gAVq+w
G7uys3NzhTEYjV9RIsoZollq+j/mEY31MblVxDPX3pjiL2M5Ig5uDjEuwAEjYTDq
bDFN7NaR6Paoo1ClQ4f3XQKBgCsnAaObuCaSEhz48Z+T6oKQTznXBC6q5aHBXG2u
O1dgutsGyoUk8yQkOTuX5hXmbC1pc/fJnxdTIlff3xpjLcOWMKRjy3TGgELRnFQ8
FaH1H9nVFeAYNunxJ3xjos8IFqAbwKn0+QJ4TLVxL50oTBe7S0Iqds1/xajaPX0R
aBphAoGANtAo+OeABWmZpjliuDNH38wsAg0bfOCABwHA9JL5T2RoTMds4kGhG1qb
NYBMJpTGZ2ZuDw63EeMIQC9Qjfmzo1gor2btC7JzovxvOCADHmZFzuiwnt0iHN+9
YK9yDt+rcQk7TJSAHwwPwr5vgiheNwgnXyAsyCUfMBZZ7KbqJvg=
-----END RSA PRIVATE KEY-----''';

    try {
      final ctx = SecurityContext(withTrustedRoots: false);
      ctx.useCertificateChainBytes(utf8.encode(_testCert));
      ctx.usePrivateKeyBytes(utf8.encode(_testKey));

      _socket = await SecureSocket.connect(
        ip, _remotePort,
        context: ctx,
        onBadCertificate: (_) => true,
        timeout: const Duration(seconds: 5),
      );

      _connected = true;
      _connectedAt = DateTime.now();
      _log('stream listener sayısı: add(true) öncesi');
      _connCtrl.add(true);
      _log('Bağlandı: $ip:$_remotePort — stream.add(true) gönderildi');

      _socket!.listen(
        _onData,
        onError: (e) { _log('Socket error: $e'); _onDisconnect(); },
        onDone:  ()  { _log('Socket closed'); _onDisconnect(); },
      );

      // Bağlantı kurulunca hemen configure+setActive gönder
      // (TV'nin configure mesajını beklemeye gerek yok)
      Future.delayed(const Duration(milliseconds: 100), () {
        _sendConfigure();
        Future.delayed(const Duration(milliseconds: 100), _sendSetActive);
      });

      // Ping her 5 sn
      _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) => _sendPing());
      return true;
    } catch (e) {
      _log('Bağlantı hatası: $e');
      _connected = false;
      _connCtrl.add(false);
      return false;
    }
  }

  void _onData(List<int> data) {
    _log('← raw(${data.length}b): ${data.take(8).map((b) => b.toRadixString(16).padLeft(2,"0")).join(" ")}');
    _recvBuf.addAll(data);
    // 4-byte length prefix parse
    while (_recvBuf.length >= 4) {
      final len = ByteData.sublistView(Uint8List.fromList(_recvBuf.sublist(0, 4)))
          .getUint32(0, Endian.big);
      _log('← len=$len bufSize=${_recvBuf.length}');
      if (_recvBuf.length < 4 + len) break;
      final msg = _recvBuf.sublist(4, 4 + len);
      _recvBuf.removeRange(0, 4 + len);
      _handleMessage(msg);
    }
  }

  void _handleMessage(List<int> msg) {
    if (msg.isEmpty) return;
    final hex = msg.take(16).map((b) => b.toRadixString(16).padLeft(2,'0')).join(' ');
    _log('← msg(${msg.length}b): $hex');

    final tag = msg[0];
    // field 1 (0x0A) = remote_configure — TV ilk mesajı gönderir
    if (tag == 0x0A) {
      _log('→ configure response gönderiliyor');
      _sendConfigure();
      Future.delayed(const Duration(milliseconds: 100), _sendSetActive);
    }
    // field 8 (0x42) = ping_request
    else if (tag == 0x42) {
      _log('→ pong gönderiliyor');
      _sendPong(msg);
    }
    // field 9 (0x4A) = ping_response — yoksay
    else if (tag == 0x4A) {}
    // field 2 (0x12) = remote_set_active response — bağlantı hazır
    else if (tag == 0x12) {
      _log('✓ Handshake tamamlandı');
    }
    else {
      _log('bilinmeyen tag: 0x${tag.toRadixString(16)}');
    }
  }

  void _sendConfigure() {
    // Python referans: code1=615, device_info { unknown1=1, unknown2="1", package_name, app_version }
    // model ve vendor gönderilmiyor — Python implementasyonuyla birebir
    final info = _ProtoWriter()
      ..writeVarint(3, 1)                  // unknown1
      ..writeString(4, '1')                // unknown2
      ..writeString(5, 'com.mibox.remote') // package_name
      ..writeString(6, '1.0.0');           // app_version

    final cfg = _ProtoWriter()
      ..writeVarint(1, 615)
      ..writeBytes(2, info.toBytes());

    final msg = _ProtoWriter()..writeBytes(1, cfg.toBytes());
    _sendMessage(msg.toBytes());
    _log('→ configure gönderildi (code1=615)');
  }

  void _sendSetActive() {
    // RemoteSetActive { active=1: 1 }
    final active = _ProtoWriter()..writeVarint(1, 615);
    // RemoteMessage { remote_set_active=2: active }
    final msg = _ProtoWriter()..writeBytes(2, active.toBytes());
    _sendMessage(msg.toBytes());
    _log('→ set_active gönderildi');
  }

  // Pong: RemoteMessage { remote_ping_response=9: { val1: same as request } }
  void _sendPong(List<int> pingMsg) {
    // field 9 = 0x4A, ping_response field 9 = 0x4A
    // basit: gelen val1'i geri yansıt
    _sendMessage(Uint8List.fromList([0x4A, 0x02, 0x08, 0x00]));
  }

  // Ping: RemoteMessage { remote_ping_request=8: { val1: 1 } }
  void _sendPing() {
    if (!_connected) return;
    try {
      _sendMessage(Uint8List.fromList([0x42, 0x02, 0x08, 0x00]));
    } catch (_) {
      _onDisconnect();
    }
  }

  // ── Tuş komutları ──────────────────────────────────────────────────────────
  // RemoteMessage field 10 = remote_key_inject { key_code=1, direction=2 }
  // RemoteDirection: SHORT=3, START_LONG=1, END_LONG=2

  void sendKey(int keyCode, {bool longPress = false}) {
    if (!_connected) return;
    if (longPress) {
      _sendKeyDirection(keyCode, 1); // START_LONG
      Future.delayed(const Duration(milliseconds: 600), () {
        _sendKeyDirection(keyCode, 2); // END_LONG
      });
    } else {
      _sendKeyDirection(keyCode, 3); // SHORT — tek seferlik
    }
  }

  void _sendKeyDirection(int keyCode, int direction) {
    // RemoteMessage { remote_key_inject=10: { key_code=1: keyCode, direction=2: direction } }
    final inner = _ProtoWriter()
      ..writeVarint(1, keyCode)    // key_code
      ..writeVarint(2, direction); // direction
    final outer = _ProtoWriter()..writeBytes(10, inner.toBytes()); // field 10
    _sendMessage(outer.toBytes());
  }

  /// SHORT tıklama
  void sendClick() => sendKey(AtvKey.dpadCenter);

  /// Uzun basma
  void sendLongClick() => sendKey(AtvKey.dpadCenter, longPress: true);

  // ── Düşük seviye ────────────────────────────────────────────────────────────
  // Format: [4-byte big-endian length][payload]
  void _sendMessage(Uint8List payload) {
    if (_socket == null || !_connected) return;
    try {
      final lenBytes = ByteData(4);
      lenBytes.setUint32(0, payload.length, Endian.big);
      _log('→ send(${payload.length}b): ${payload.take(8).map((b) => b.toRadixString(16).padLeft(2,"0")).join(" ")}');
      _socket!.add(lenBytes.buffer.asUint8List());
      _socket!.add(payload);
    } catch (e) {
      _log('send error: $e');
      _onDisconnect();
    }
  }

  DateTime? _connectedAt;

  void _onDisconnect() {
    final uptime = _connectedAt != null
        ? DateTime.now().difference(_connectedAt!).inMilliseconds
        : -1;
    _log('Bağlantı kesildi — uptime: ${uptime}ms');
    _connected = false;
    _pingTimer?.cancel();
    _connCtrl.add(false);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 4), () {
      if (!_connected && _ip.isNotEmpty) connect(_ip, remotePort: _remotePort);
    });
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _socket?.destroy();
    _connected = false;
    _connCtrl.close();
  }
}

// ── Protobuf yazar ─────────────────────────────────────────────────────────────
class _ProtoWriter {
  final List<int> _buf = [];

  void writeVarint(int field, int value) {
    _writeRawVarint((field << 3) | 0);
    _writeRawVarint(value);
  }

  void writeString(int field, String value) {
    final bytes = utf8.encode(value);
    _writeRawVarint((field << 3) | 2);
    _writeRawVarint(bytes.length);
    _buf.addAll(bytes);
  }

  void writeBytes(int field, Uint8List value) {
    _writeRawVarint((field << 3) | 2);
    _writeRawVarint(value.length);
    _buf.addAll(value);
  }

  void _writeRawVarint(int v) {
    v = v & 0xFFFFFFFF;
    while (v > 0x7F) {
      _buf.add((v & 0x7F) | 0x80);
      v >>= 7;
    }
    _buf.add(v & 0x7F);
  }

  Uint8List toBytes() => Uint8List.fromList(_buf);
}

// ── Android KeyEvent sabitleri ─────────────────────────────────────────────────
class AtvKey {
  static const int volumeUp   = 24;
  static const int volumeDown = 25;
  static const int volumeMute = 164;
  static const int home       = 3;
  static const int back       = 4;
  static const int dpadUp     = 19;
  static const int dpadDown   = 20;
  static const int dpadLeft   = 21;
  static const int dpadRight  = 22;
  static const int dpadCenter = 23;
  static const int playPause  = 85;
  static const int mediaNext  = 87;
  static const int mediaPrev  = 88;
  static const int mediaStop  = 86;
  static const int power      = 26;
  static const int enter      = 66;
  static const int del        = 67;
  static const int tab        = 61;
  static const int search     = 84;
  static const int settings   = 176;
}
