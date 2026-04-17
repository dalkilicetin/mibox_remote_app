import 'dart:async';
import 'dart:convert';
import 'dart:io';

class MiBoxService {
  static const int CURSOR_PORT = 9876;
  static const int SCREEN_W = 1920;
  static const int SCREEN_H = 1080;

  Socket? _socket;
  bool _connected = false;
  String _ip = '';

  int cursorX = SCREEN_W ~/ 2;
  int cursorY = SCREEN_H ~/ 2;

  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connectionController.stream;
  bool get isConnected => _connected;

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
              final j = jsonDecode(line);
              if (j['x'] != null) cursorX = j['x'];
              if (j['y'] != null) cursorY = j['y'];
            } catch (_) {}
          }
        },
        onError: (_) => _onDisconnect(),
        onDone: () => _onDisconnect(),
      );

      print('[APK] Baglandi: $ip:$CURSOR_PORT');
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
    required int x1,
    required int y1,
    required int x2,
    required int y2,
    int duration = 150,
  }) {
    if (!_connected) return;
    _send({
      'type': 'swipe',
      'x1': x1,
      'y1': y1,
      'x2': x2,
      'y2': y2,
      'duration': duration,
    });
  }

  void _send(Map<String, dynamic> obj) {
    try {
      _socket?.write(jsonEncode(obj) + '\n');
    } catch (e) {
      print('[APK] Gonderme hatasi: $e');
      _onDisconnect();
    }
  }

  void dispose() {
    _socket?.destroy();
    _connected = false;
    _connectionController.close();
  }
}
