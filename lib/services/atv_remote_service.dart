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
  Timer? _configureTimer;
  bool _configured = false;

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

  // Varint length prefix için buffer
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
      _connectedAt = DateTime.now();
      _log('stream listener sayısı: add(true) öncesi');
      _connCtrl.add(true);
      _log('Bağlandı: $ip:$_remotePort — stream.add(true) gönderildi');

      _socket!.listen(
        _onData,
        onError: (e) { _log('Socket error: $e'); _onDisconnect(); },
        onDone:  ()  { _log('Socket closed'); _onDisconnect(); },
      );

      // TV'den configure gelince cevap vereceğiz (_handleMessage)
      // Fallback: 2 saniye içinde TV mesaj göndermezse biz başlatalım
      _configureTimer = Timer(const Duration(seconds: 2), () {
        if (_connected && !_configured) {
          _log('→ fallback configure (TV mesaj göndermedi)');
          _sendConfigure();
          Future.delayed(const Duration(milliseconds: 100), _sendSetActive);
        }
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
    // Varint length prefix parse
    while (_recvBuf.isNotEmpty) {
      // Varint decode — incomplete varint koruması ile
      int len = 0;
      int shift = 0;
      int varintBytes = 0;
      bool varintComplete = false;
      for (var i = 0; i < _recvBuf.length && i < 5; i++) {
        final b = _recvBuf[i];
        len |= (b & 0x7F) << shift;
        shift += 7;
        varintBytes++;
        if ((b & 0x80) == 0) { varintComplete = true; break; }
      }
      // Varint tamamlanmadıysa daha fazla veri bekle
      if (!varintComplete || _recvBuf.length < varintBytes + len) break;
      final msg = _recvBuf.sublist(varintBytes, varintBytes + len);
      _recvBuf.removeRange(0, varintBytes + len);
      _log('← msg(${len}b): ${msg.take(8).map((b) => b.toRadixString(16).padLeft(2,"0")).join(" ")}');
      _handleMessage(msg);
    }
  }

  void _handleMessage(List<int> msg) {
    if (msg.isEmpty) return;
    final tag = msg[0];
    // field 1 (0x0A) = remote_configure — TV ilk mesajı gönderir
    if (tag == 0x0A) {
      _configureTimer?.cancel();
      if (!_configured) {
        _configured = true;
        _log('→ configure gönderiliyor (TV tetikledi)');
        _sendConfigure();
        Future.delayed(const Duration(milliseconds: 100), _sendSetActive);
      } else {
        _log('← configure (tekrar) — yoksayıldı');
      }
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
    // pingMsg gövdesi: [0x42, <varint len>, 0x08, <val1 varint...>]
    // field 1 (0x08) = val1 — ping'den aynı değeri yansıt
    int val1 = 0;
    // varint prefix'i atla: index 0 = tag(0x42), index 1 = len, index 2 = 0x08, index 3+ = val1
    if (pingMsg.length >= 4 && pingMsg[2] == 0x08) {
      int shift = 0;
      for (var i = 3; i < pingMsg.length && i < 3 + 5; i++) {
        val1 |= (pingMsg[i] & 0x7F) << shift;
        shift += 7;
        if ((pingMsg[i] & 0x80) == 0) break;
      }
    }
    final inner = _ProtoWriter()..writeVarint(1, val1);
    final outer = _ProtoWriter()..writeBytes(9, inner.toBytes());
    _sendMessage(outer.toBytes());
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
  // Format: [varint length][payload] — ATV v2 protokolü
  void _sendMessage(Uint8List payload) {
    if (_socket == null || !_connected) return;
    try {
      final varint = _encodeVarint(payload.length);
      _log('→ send(${payload.length}b prefix=${varint.map((b)=>b.toRadixString(16).padLeft(2,"0")).join()}): ${payload.take(8).map((b) => b.toRadixString(16).padLeft(2,"0")).join(" ")}');
      _socket!.add(varint);
      _socket!.add(payload);
    } catch (e) {
      _log('send error: $e');
      _onDisconnect();
    }
  }

  static Uint8List _encodeVarint(int value) {
    value = value.toUnsigned(32); // negatif değerlere karşı güvenlik
    final bytes = <int>[];
    while (value > 0x7F) {
      bytes.add((value & 0x7F) | 0x80);
      value >>= 7;
    }
    bytes.add(value & 0x7F);
    return Uint8List.fromList(bytes);
  }

  DateTime? _connectedAt;

  void _onDisconnect() {
    _configured = false;
    _configureTimer?.cancel();
    _recvBuf.clear();
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
    _configureTimer?.cancel();
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
