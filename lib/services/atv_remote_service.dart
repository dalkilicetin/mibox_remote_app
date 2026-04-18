import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// AndroidTV Remote Protocol v2 — port 6466, TLS
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
        onError: (_) => _onDisconnect(),
        onDone:  ()  => _onDisconnect(),
      );

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
    // TV'den gelen pong / status mesajları — şimdilik yoksay
  }

  void _onDisconnect() {
    _connected = false;
    _pingTimer?.cancel();
    _connCtrl.add(false);
    print('[ATV] Bağlantı kesildi — 4 sn sonra yeniden denenecek');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 4), () {
      if (!_connected && _ip.isNotEmpty) connect(_ip);
    });
  }

  void _sendPing() {
    if (!_connected) return;
    try {
      _sendMessage(Uint8List.fromList([0x08, 0x00]));
    } catch (_) {
      _onDisconnect();
    }
  }

  // ── Tuş komutları ──────────────────────────────────────────────────────

  void sendKey(int keyCode, {bool longPress = false}) {
    if (!_connected) return;
    _sendKeyAction(keyCode, 1); // DOWN
    Future.delayed(Duration(milliseconds: longPress ? 600 : 80), () {
      _sendKeyAction(keyCode, 2); // UP
    });
  }

  void _sendKeyAction(int keyCode, int action) {
    // RemoteMessage protobuf: field 4 = key_event { field 1 = keycode, field 2 = action }
    final inner = _ProtoWriter()
      ..writeVarint(1, keyCode)
      ..writeVarint(2, action);
    final outer = _ProtoWriter()..writeBytes(4, inner.toBytes());
    _sendMessage(outer.toBytes());
  }

  // ── Mouse / tap (ATV Remote protokolü mouse event destekliyor) ──────────

  /// Rölatif mouse hareketi gönderir.
  /// field 5 = mouse_event { field 1 = x_delta, field 2 = y_delta }
  void sendMouseMove(int dx, int dy) {
    if (!_connected) return;
    final inner = _ProtoWriter()
      ..writeVarintSigned(1, dx)
      ..writeVarintSigned(2, dy);
    final outer = _ProtoWriter()..writeBytes(5, inner.toBytes());
    _sendMessage(outer.toBytes());
  }

  /// Tek tıklama: DPAD_CENTER DOWN + UP
  void sendClick() => sendKey(AtvKey.dpadCenter);

  /// Uzun basma: DPAD_CENTER long press
  void sendLongClick() => sendKey(AtvKey.dpadCenter, longPress: true);

  // ── Düşük seviye ────────────────────────────────────────────────────────

  /// Format: [4-byte big-endian length][payload]
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

  void dispose() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _socket?.destroy();
    _connected = false;
    _connCtrl.close();
  }
}

// ── Protobuf yazar ───────────────────────────────────────────────────────────
class _ProtoWriter {
  final List<int> _buf = [];

  void writeVarint(int field, int value) {
    _writeRawVarint((field << 3) | 0);
    _writeRawVarint(value);
  }

  /// Zigzag encode — signed int için (mouse delta)
  void writeVarintSigned(int field, int value) {
    _writeRawVarint((field << 3) | 0);
    final zigzag = (value << 1) ^ (value >> 31);
    _writeRawVarint(zigzag);
  }

  void writeBytes(int field, Uint8List value) {
    _writeRawVarint((field << 3) | 2);
    _writeRawVarint(value.length);
    _buf.addAll(value);
  }

  void _writeRawVarint(int v) {
    v = v & 0xFFFFFFFF; // 32-bit sınır
    while (v > 0x7F) {
      _buf.add((v & 0x7F) | 0x80);
      v >>= 7;
    }
    _buf.add(v & 0x7F);
  }

  Uint8List toBytes() => Uint8List.fromList(_buf);
}

// ── Android KeyEvent sabitleri ───────────────────────────────────────────────
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
}
