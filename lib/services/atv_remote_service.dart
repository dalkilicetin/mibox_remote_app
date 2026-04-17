import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// AndroidTV Remote Protocol v2
/// Port 6466, TLS ile baglanti
/// Sertifika: mibox_cert.pem / mibox_key.pem
class AtvRemoteService {
  static const int REMOTE_PORT = 6466;
  static const String MI_BOX_IP = '192.168.1.109';

  SecureSocket? _socket;
  bool _connected = false;
  int _sequence = 0;
  Timer? _pingTimer;

  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connectionController.stream;
  bool get isConnected => _connected;

  // Sertifika PEM icerik - assets'ten yuklenecek
  String _certPem = '';
  String _keyPem = '';

  void setCertificates(String cert, String key) {
    _certPem = cert;
    _keyPem = key;
  }

  Future<bool> connect(String ip) async {
    if (_certPem.isEmpty || _keyPem.isEmpty) {
      print('[ATV] Sertifika yok!');
      return false;
    }
    try {
      // PEM'den SecurityContext olustur
      final context = SecurityContext(withTrustedRoots: false);
      context.useCertificateChainBytes(utf8.encode(_certPem));
      context.usePrivateKeyBytes(utf8.encode(_keyPem));

      _socket = await SecureSocket.connect(
        ip,
        REMOTE_PORT,
        context: context,
        onBadCertificate: (_) => true, // TV sertifikasini kabul et
        timeout: const Duration(seconds: 5),
      );

      _connected = true;
      _connectionController.add(true);
      print('[ATV] Baglandi: $ip:$REMOTE_PORT');

      // Veri dinle
      _socket!.listen(
        (data) => _onData(data),
        onError: (_) => _onDisconnect(),
        onDone: () => _onDisconnect(),
      );

      // Ping gonder (baglanti canli tut)
      _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) => _sendPing());

      return true;
    } catch (e) {
      print('[ATV] Baglanti hatasi: $e');
      _connected = false;
      _connectionController.add(false);
      return false;
    }
  }

  void _onData(List<int> data) {
    // TV'den gelen mesajlari isle (pong vs)
    print('[ATV] Veri alindi: ${data.length} byte');
  }

  void _onDisconnect() {
    _connected = false;
    _pingTimer?.cancel();
    _connectionController.add(false);
    print('[ATV] Baglanti kesildi');
    // 3 saniye sonra yeniden baglan
    Timer(const Duration(seconds: 3), () {
      if (!_connected) connect(MI_BOX_IP);
    });
  }

  void _sendPing() {
    if (!_connected) return;
    try {
      // Ping mesaji: 0x08 0x00 (protobuf: field 1, varint 0)
      _sendMessage(Uint8List.fromList([0x08, 0x00]));
    } catch (e) {
      _onDisconnect();
    }
  }

  /// AndroidTV Remote protokolu mesaj formati:
  /// [4 byte big-endian length][payload]
  void _sendMessage(Uint8List payload) {
    if (_socket == null || !_connected) return;
    final lenBytes = ByteData(4);
    lenBytes.setUint32(0, payload.length, Endian.big);
    _socket!.add(lenBytes.buffer.asUint8List());
    _socket!.add(payload);
  }

  /// Key event gonder
  /// format: protobuf RemoteMessage
  /// field 4 (key_event): field 1 (keycode), field 2 (action)
  void sendKey(int keyCode, {bool longPress = false}) {
    if (!_connected) return;
    try {
      // ACTION_DOWN
      _sendKeyAction(keyCode, 1);
      // ACTION_UP (kisa bekle)
      Future.delayed(Duration(milliseconds: longPress ? 500 : 50), () {
        _sendKeyAction(keyCode, 2);
      });
    } catch (e) {
      print('[ATV] Key error: $e');
    }
  }

  void _sendKeyAction(int keyCode, int action) {
    // RemoteMessage protobuf:
    // field 4 (key_event) = {
    //   field 1 (keycode) = keyCode
    //   field 2 (action) = action (1=DOWN, 2=UP)
    // }
    final payload = _buildKeyEventMessage(keyCode, action);
    _sendMessage(payload);
  }

  Uint8List _buildKeyEventMessage(int keyCode, int action) {
    final writer = _ProtoWriter();
    // Inner message: key_event
    final inner = _ProtoWriter();
    inner.writeVarint(1, keyCode);  // field 1: keycode
    inner.writeVarint(2, action);   // field 2: action
    writer.writeBytes(4, inner.toBytes()); // field 4: key_event
    return writer.toBytes();
  }

  void dispose() {
    _pingTimer?.cancel();
    _socket?.destroy();
    _connected = false;
    _connectionController.close();
  }
}

/// Basit protobuf yazar
class _ProtoWriter {
  final List<int> _buf = [];

  void writeVarint(int fieldNumber, int value) {
    // Tag: (fieldNumber << 3) | 0 (varint)
    _writeRawVarint((fieldNumber << 3) | 0);
    _writeRawVarint(value);
  }

  void writeBytes(int fieldNumber, Uint8List value) {
    // Tag: (fieldNumber << 3) | 2 (length-delimited)
    _writeRawVarint((fieldNumber << 3) | 2);
    _writeRawVarint(value.length);
    _buf.addAll(value);
  }

  void _writeRawVarint(int value) {
    while (value > 0x7F) {
      _buf.add((value & 0x7F) | 0x80);
      value >>= 7;
    }
    _buf.add(value & 0x7F);
  }

  Uint8List toBytes() => Uint8List.fromList(_buf);
}

/// Android KeyEvent kodlari
class AtvKey {
  static const int VOLUME_UP = 24;
  static const int VOLUME_DOWN = 25;
  static const int VOLUME_MUTE = 164;
  static const int HOME = 3;
  static const int BACK = 4;
  static const int DPAD_UP = 19;
  static const int DPAD_DOWN = 20;
  static const int DPAD_LEFT = 21;
  static const int DPAD_RIGHT = 22;
  static const int DPAD_CENTER = 23;
  static const int PLAY_PAUSE = 85;
  static const int MEDIA_NEXT = 87;
  static const int MEDIA_PREV = 88;
  static const int MEDIA_STOP = 86;
  static const int POWER = 26;
  static const int SLEEP = 223;
  static const int ENTER = 66;
  static const int DEL = 67;
}
