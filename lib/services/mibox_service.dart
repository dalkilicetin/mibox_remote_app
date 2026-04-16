import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class MiBoxService {
  static const int CURSOR_PORT = 9876;
  static const int SCREEN_W = 1920;
  static const int SCREEN_H = 1080;

  Socket? _cursorSocket;
  bool _connected = false;
  String _ip = '';

  // Cursor pozisyonu
  int cursorX = SCREEN_W ~/ 2;
  int cursorY = SCREEN_H ~/ 2;

  final StreamController<bool> _connectionController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connectionController.stream;

  bool get isConnected => _connected;

  // Bağlan
  Future<bool> connect(String ip) async {
    _ip = ip;
    try {
      _cursorSocket = await Socket.connect(ip, CURSOR_PORT, timeout: const Duration(seconds: 5));
      _connected = true;
      _connectionController.add(true);

      // İlk mesajı oku (ekran boyutu + cursor pozisyonu)
      _cursorSocket!.listen(
        (data) {
          final msg = utf8.decode(data).trim();
          for (final line in msg.split('\n')) {
            if (line.isEmpty) continue;
            try {
              final j = jsonDecode(line);
              if (j['x'] != null) cursorX = j['x'];
              if (j['y'] != null) cursorY = j['y'];
            } catch (_) {}
          }
        },
        onError: (_) => _onDisconnect(),
        onDone: () => _onDisconnect(),
      );

      print('[APK] Bağlandı: $ip:$CURSOR_PORT');
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
    print('[APK] Bağlantı kesildi');
  }

  void disconnect() {
    _cursorSocket?.destroy();
    _connected = false;
    _connectionController.add(false);
  }

  // Cursor hareket (delta)
  void moveCursor(int dx, int dy) {
    if (!_connected) return;
    cursorX = (cursorX + dx).clamp(0, SCREEN_W);
    cursorY = (cursorY + dy).clamp(0, SCREEN_H);
    _send({'type': 'move', 'dx': dx, 'dy': dy});
  }

  // Cursor mutlak pozisyon (lazer pointer)
  void setCursorPos(int x, int y) {
    if (!_connected) return;
    x = x.clamp(0, SCREEN_W);
    y = y.clamp(0, SCREEN_H);
    final dx = x - cursorX;
    final dy = y - cursorY;
    cursorX = x;
    cursorY = y;
    if (dx != 0 || dy != 0) {
      _send({'type': 'move', 'dx': dx, 'dy': dy});
    }
  }

  // Tıklama
  void tap() {
    if (!_connected) return;
    _send({'type': 'tap'});
  }

  void _send(Map<String, dynamic> obj) {
    try {
      final data = jsonEncode(obj) + '\n';
      _cursorSocket?.write(data);
    } catch (e) {
      print('[APK] Gönderme hatası: $e');
      _onDisconnect();
    }
  }

  void dispose() {
    disconnect();
    _connectionController.close();
  }
}
