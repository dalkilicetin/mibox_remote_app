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

  final StreamController<bool> _connCtrl = StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connCtrl.stream;
  bool get isConnected => _connected;

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
      print('[ATV] Sertifika yok — pairing gerekli');
      return false;
    }
    try {
      final ctx = SecurityContext(withTrustedRoots: false);
      ctx.useCertificateChainBytes(utf8.encode(_certPem));
      ctx.usePrivateKeyBytes(utf8.encode(_keyPem));

      _socket = await SecureSocket.connect(
        ip, _remotePort,
        context: ctx,
        onBadCertificate: (_) => true,
        timeout: const Duration(seconds: 5),
      );

      _connected = true;
      _connCtrl.add(true);
      print('[ATV] Bağlandı: $ip:$_remotePort');

      _socket!.listen(
        _onData,
        onError: (e) { print('[ATV] Socket error: $e'); _onDisconnect(); },
        onDone:  ()  { print('[ATV] Socket closed'); _onDisconnect(); },
      );

      // Ping her 5 sn
      _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) => _sendPing());
      return true;
    } catch (e) {
      print('[ATV] Bağlantı hatası: $e');
      _connected = false;
      _connCtrl.add(false);
      return false;
    }
  }

  void _onData(List<int> data) {
    _recvBuf.addAll(data);
    // 4-byte length prefix parse
    while (_recvBuf.length >= 4) {
      final len = ByteData.sublistView(Uint8List.fromList(_recvBuf.sublist(0, 4)))
          .getUint32(0, Endian.big);
      if (_recvBuf.length < 4 + len) break;
      final msg = _recvBuf.sublist(4, 4 + len);
      _recvBuf.removeRange(0, 4 + len);
      _handleMessage(msg);
    }
  }

  void _handleMessage(List<int> msg) {
    if (msg.isEmpty) return;
    final hex = msg.take(16).map((b) => b.toRadixString(16).padLeft(2,'0')).join(' ');
    print('[ATV] ← msg(${msg.length}b): $hex');

    final tag = msg[0];
    // field 1 (0x0A) = remote_configure — TV ilk mesajı gönderir
    if (tag == 0x0A) {
      print('[ATV] → configure response gönderiliyor');
      _sendConfigure();
      Future.delayed(const Duration(milliseconds: 100), _sendSetActive);
    }
    // field 8 (0x42) = ping_request
    else if (tag == 0x42) {
      print('[ATV] → pong gönderiliyor');
      _sendPong(msg);
    }
    // field 9 (0x4A) = ping_response — yoksay
    else if (tag == 0x4A) {}
    // field 2 (0x12) = remote_set_active response — bağlantı hazır
    else if (tag == 0x12) {
      print('[ATV] ✓ Handshake tamamlandı');
    }
    else {
      print('[ATV] bilinmeyen tag: 0x${tag.toRadixString(16)}');
    }
  }

  // RemoteMessage { remote_configure=1: { code1=1: 622 (0x26E), device_info=2: {...} } }
  void _sendConfigure() {
    // Aymkdn doc'tan exact bytes: [10,34,8,238,4,18,29,24,1,34,1,49,42,15,androidtv-remote,50,5,1.0.0]
    const pkg = [97,110,100,114,111,105,100,116,118,45,114,101,109,111,116,101]; // androidtv-remote
    const ver = [49,46,48,46,48]; // 1.0.0
    // sub = device_info: {unknown1=3: 1, unknown2=4: "1", package_name=5: pkg, app_version=6: ver}
    final sub = <int>[24,1, 34,1,49, 42,pkg.length,...pkg, 50,ver.length,...ver];
    final payload = <int>[10, sub.length+2, 8,238,4, 18,sub.length, ...sub];
    _sendMessage(Uint8List.fromList(payload));
    print('[ATV] → configure gönderildi');
  }

  // RemoteMessage { remote_set_active=2: { active=1: 622 } }
  void _sendSetActive() {
    // [18,3,8,238,4]
    _sendMessage(Uint8List.fromList([18, 3, 8, 238, 4]));
    print('[ATV] → set_active gönderildi');
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
      _socket!.add(lenBytes.buffer.asUint8List());
      _socket!.add(payload);
    } catch (_) {
      _onDisconnect();
    }
  }

  void _onDisconnect() {
    _connected = false;
    _pingTimer?.cancel();
    _connCtrl.add(false);
    print('[ATV] Bağlantı kesildi — 4 sn sonra yeniden denenecek');
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
