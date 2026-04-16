import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

// Android TV Remote Protocol v2 - basit TCP implementasyon
// Pairing yapılmışsa cert/key ile TLS bağlantısı
// Bu versiyonda ADB üzerinden key event göndereceğiz
class AtvService {
  // ADB üzerinden komut gönder (Wi-Fi üzerinden)
  final String _ip;
  
  AtvService(this._ip);

  // Key kodları
  static const Map<String, int> keyCodes = {
    'up': 19,
    'down': 20,
    'left': 21,
    'right': 22,
    'center': 23,
    'back': 4,
    'home': 3,
    'play_pause': 85,
    'volume_up': 24,
    'volume_down': 25,
    'menu': 82,
    'search': 84,
  };

  Future<void> sendKey(String key) async {
    final code = keyCodes[key];
    if (code == null) return;
    try {
      await Process.run('adb', ['-s', '$_ip:5555', 'shell', 'input', 'keyevent', '$code']);
    } catch (e) {
      print('[ATV] Key error: $e');
    }
  }

  Future<void> sendTap(int x, int y) async {
    try {
      await Process.run('adb', ['-s', '$_ip:5555', 'shell', 'input', 'tap', '$x', '$y']);
    } catch (e) {
      print('[ATV] Tap error: $e');
    }
  }
}
