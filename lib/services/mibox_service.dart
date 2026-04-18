import 'dart:async';
import 'dart:convert';
import 'dart:io';

class MiBoxService {
  static const int CURSOR_PORT = 9876;
  static const int UDP_DISCOVERY_PORT = 9877;
  static const String DISCOVERY_MAGIC = 'AIRCURSOR_DISCOVER';
  static const int SCREEN_W = 1920;
  static const int SCREEN_H = 1080;

  Socket? _socket;
  bool _connected = false;
  String _ip = '';

  int cursorX = SCREEN_W ~/ 2;
  int cursorY = SCREEN_H ~/ 2;

  // APK'dan gelen ATV port bilgileri
  int atvPairingPort = 6467;
  int atvRemotePort  = 6466;

  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connectionController.stream;
  bool get isConnected => _connected;

  // UDP broadcast ile ağdaki tüm AirCursor APK'ları bul
  // Her bulunan cihaz callback'e gönderilir: {ip, cursorPort, atvPairingPort, atvRemotePort}
  static Future<List<Map<String, dynamic>>> discoverDevices({
    Duration timeout = const Duration(seconds: 3),
    void Function(Map<String, dynamic>)? onDeviceFound,
  }) async {
    final found = <Map<String, dynamic>>[];
    RawDatagramSocket? udpSocket;

    try {
      udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      udpSocket.broadcastEnabled = true;

      // Tüm subnet broadcast adreslerine gönder
      final broadcastAddresses = await _getBroadcastAddresses();
      final msg = utf8.encode(DISCOVERY_MAGIC);

      for (final addr in broadcastAddresses) {
        try {
          udpSocket.send(msg, InternetAddress(addr), UDP_DISCOVERY_PORT);
        } catch (_) {}
      }

      final completer = Completer<void>();
      Timer(timeout, () { if (!completer.isCompleted) completer.complete(); });

      udpSocket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = udpSocket!.receive();
          if (datagram == null) return;
          try {
            final response = utf8.decode(datagram.data);
            final json = jsonDecode(response) as Map<String, dynamic>;
            if (json['service'] == 'aircursor') {
              final device = {
                'ip': datagram.address.address,
                'cursorPort':     json['cursorPort']     ?? CURSOR_PORT,
                'atvPairingPort': json['atvPairingPort'] ?? 6467,
                'atvRemotePort':  json['atvRemotePort']  ?? 6466,
                'w':              json['w']              ?? SCREEN_W,
                'h':              json['h']              ?? SCREEN_H,
              };
              found.add(device);
              onDeviceFound?.call(device);
            }
          } catch (_) {}
        }
      });

      await completer.future;
    } catch (e) {
      print('[DISCOVERY] UDP error: $e');
    } finally {
      udpSocket?.close();
    }

    return found;
  }

  static Future<List<String>> _getBroadcastAddresses() async {
    final addresses = <String>[];
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            // /24 subnet broadcast (255.255.255.0 mask varsayımı)
            addresses.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
          }
        }
      }
    } catch (_) {}
    if (addresses.isEmpty) addresses.add('255.255.255.255');
    return addresses;
  }

  Future<bool> connect(String ip) async {
    _ip = ip;
    try {
      _socket = await Socket.connect(ip, CURSOR_PORT,
          timeout: const Duration(seconds: 5));
      _connected = true;
      _connectionController.add(true);

      _socket!.listen(
        (data) {
          final msg = utf8.decode(data).trim();
          for (final line in msg.split('\n')) {
            if (line.isEmpty) continue;
            try {
              final j = jsonDecode(line) as Map<String, dynamic>;
              if (j['x'] != null) cursorX = j['x'];
              if (j['y'] != null) cursorY = j['y'];
              // APK'dan gelen ATV port bilgileri
              if (j['atvPairingPort'] != null) atvPairingPort = j['atvPairingPort'];
              if (j['atvRemotePort']  != null) atvRemotePort  = j['atvRemotePort'];
            } catch (_) {}
          }
        },
        onError: (_) => _onDisconnect(),
        onDone: () => _onDisconnect(),
      );

      print('[APK] Bağlandı: $ip:$CURSOR_PORT — ATV pairing:$atvPairingPort remote:$atvRemotePort');
      return true;
    } catch (e) {
      print('[APK] Hata: $e');
      _connected = false;
      _connectionController.add(false);
      return false;
    }
  }

  void _onDisconnect() {
    _connected = false;
    _connectionController.add(false);
  }

  void moveCursor(int dx, int dy) {
    if (!_connected) return;
    cursorX = (cursorX + dx).clamp(0, SCREEN_W);
    cursorY = (cursorY + dy).clamp(0, SCREEN_H);
    _send({'type': 'move', 'dx': dx, 'dy': dy});
  }

  void tap() {
    if (!_connected) return;
    _send({'type': 'tap'});
  }

  void sendKey(int keyCode) {
    if (!_connected) return;
    _send({'type': 'key', 'code': keyCode});
  }

  void sendText(String text) {
    if (!_connected) return;
    _send({'type': 'text', 'value': text});
  }

  void hideCursor() {
    if (!_connected) return;
    _send({'type': 'hide'});
  }

  void showCursor() {
    if (!_connected) return;
    final dx = SCREEN_W ~/ 2 - cursorX;
    final dy = SCREEN_H ~/ 2 - cursorY;
    _send({'type': 'move', 'dx': dx, 'dy': dy});
    Future.delayed(const Duration(milliseconds: 50), () {
      _send({'type': 'show'});
    });
  }

  void setScrollMode(int mode) {
    if (!_connected) return;
    _send({'type': 'scroll_mode', 'mode': mode});
    if (mode != 0) {
      Future.delayed(const Duration(milliseconds: 500), () {
        _send({'type': 'scroll_mode', 'mode': 0});
      });
    }
  }

  void sendSwipe({
    required int x1, required int y1,
    required int x2, required int y2,
    int duration = 150,
  }) {
    if (!_connected) return;
    _send({'type': 'swipe', 'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2, 'duration': duration});
  }

  void _send(Map<String, dynamic> obj) {
    try {
      _socket?.write(jsonEncode(obj) + '\n');
    } catch (e) {
      print('[APK] Gönderme hatası: $e');
      _onDisconnect();
    }
  }

  void dispose() {
    _socket?.destroy();
    _connected = false;
    _connectionController.close();
  }
}
