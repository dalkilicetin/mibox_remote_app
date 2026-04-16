import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../services/mibox_service.dart';

class AirMouseScreen extends StatefulWidget {
  final MiBoxService service;
  const AirMouseScreen({super.key, required this.service});

  @override
  State<AirMouseScreen> createState() => _AirMouseScreenState();
}

class _AirMouseScreenState extends State<AirMouseScreen> {
  StreamSubscription? _gyroSub;
  bool _airOn = false;
  bool _calibrated = false;

  // Kalibrasyon referansı
  double _calibBeta  = 0;
  double _calibGamma = 0;

  // Low-pass filter
  double _filteredBeta  = 0;
  double _filteredGamma = 0;
  bool _filterInit = false;
  static const double ALPHA = 0.25;

  // Lazer pointer parametreleri
  static const double DEG_TO_PX_X = 40;
  static const double DEG_TO_PX_Y = 40;
  static const double DEAD_ZONE = 1.5;
  static const int SCREEN_W = 1920;
  static const int SCREEN_H = 1080;

  // Debug bilgisi
  String _debugText = 'Hazır';
  DateTime _lastSend = DateTime.now();

  @override
  void initState() {
    super.initState();
    _startGyro();
  }

  void _startGyro() {
    _gyroSub = gyroscopeEventStream().listen((event) {
      // gyroscopeEventStream rad/s veriyor, biz deviceorientation gibi derece istiyoruz
      // sensors_plus'ta accelerometerEvents + gyroscope kombine kullanacağız
    });

    // Orientation için accelerometer kullan
    _gyroSub?.cancel();
    _gyroSub = accelerometerEventStream().listen((event) {
      _onAccelerometer(event);
    });
  }

  void _onAccelerometer(AccelerometerEvent event) {
    // Telefon yatay + ekran tavana bakıyor pozisyonunda:
    // event.x = gamma benzeri (sol/sağ)
    // event.y = beta benzeri (ileri/geri)
    // Radyan → derece dönüşümü
    final rawBeta  = math.atan2(event.y, event.z) * 180 / math.pi;
    final rawGamma = math.atan2(event.x, event.z) * 180 / math.pi;

    // Low-pass filter
    if (!_filterInit) {
      _filteredBeta  = rawBeta;
      _filteredGamma = rawGamma;
      _filterInit = true;
      _calibBeta  = rawBeta;
      _calibGamma = rawGamma;
    }
    _filteredBeta  = ALPHA * rawBeta  + (1 - ALPHA) * _filteredBeta;
    _filteredGamma = ALPHA * rawGamma + (1 - ALPHA) * _filteredGamma;

    if (mounted) {
      setState(() {
        _debugText = 'β: ${_filteredBeta.toStringAsFixed(1)}°  γ: ${_filteredGamma.toStringAsFixed(1)}°';
      });
    }

    if (!_airOn || !_calibrated) return;

    // Rate limiting - 30fps
    final now = DateTime.now();
    if (now.difference(_lastSend).inMilliseconds < 33) return;
    _lastSend = now;

    // Kalibrasyon referansından sapma
    double dBeta  = _filteredBeta  - _calibBeta;
    double dGamma = _filteredGamma - _calibGamma;

    // Dead zone
    if (dBeta.abs()  < DEAD_ZONE) dBeta  = 0;
    if (dGamma.abs() < DEAD_ZONE) dGamma = 0;
    if (dBeta == 0 && dGamma == 0) return;

    // Piksel pozisyonu
    final px = (SCREEN_W / 2 + dGamma * DEG_TO_PX_X).round().clamp(0, SCREEN_W);
    final py = (SCREEN_H / 2 - dBeta  * DEG_TO_PX_Y).round().clamp(0, SCREEN_H);

    widget.service.setCursorPos(px, py);
  }

  void _calibrate() {
    _calibBeta  = _filteredBeta;
    _calibGamma = _filteredGamma;
    _calibrated = true;
    widget.service.setCursorPos(SCREEN_W ~/ 2, SCREEN_H ~/ 2);
    setState(() => _debugText = '✓ Kalibre edildi!');
  }

  void _toggleAir() {
    setState(() => _airOn = !_airOn);
    if (_airOn) _calibrate();
  }

  @override
  void dispose() {
    _gyroSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Debug
        Container(
          width: double.infinity,
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF0a0a1a),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            _debugText,
            style: const TextStyle(
              color: Color(0xFF4ade80),
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
        ),

        // Kalibre Et
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _calibrate,
              icon: const Icon(Icons.gps_fixed, color: Colors.white),
              label: const Text('🎯 Yeniden Kalibre Et',
                  style: TextStyle(color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0f3460),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),

        // Air Mouse toggle
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _toggleAir,
              style: ElevatedButton.styleFrom(
                backgroundColor: _airOn
                    ? const Color(0xFFe94560)
                    : const Color(0xFF16213e),
                side: const BorderSide(color: Color(0xFFe94560)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: Text(
                _airOn ? 'Air Mouse: AÇIK ✓' : 'Air Mouse: KAPALI',
                style: TextStyle(
                  color: _airOn ? Colors.white : const Color(0xFFe94560),
                  fontSize: 15,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Büyük Tıkla butonu
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: GestureDetector(
              onTapDown: (_) => widget.service.tap(),
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: const Color(0xFFe94560),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.mouse, color: Colors.white, size: 48),
                    SizedBox(height: 8),
                    Text(
                      'TIKLA',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Alt butonlar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _airBtn(Icons.arrow_back, 'Geri', () => _sendKey(4)),
              const SizedBox(width: 8),
              _airBtn(Icons.home, 'Home', () => _sendKey(3)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _airBtn(Icons.volume_up, 'Ses+', () => _sendKey(24)),
              const SizedBox(width: 8),
              _airBtn(Icons.volume_down, 'Ses-', () => _sendKey(25)),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _airBtn(IconData icon, String label, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTapDown: (_) => onTap(),
        child: Container(
          height: 60,
          decoration: BoxDecoration(
            color: const Color(0xFF16213e),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF0f3460)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(color: Colors.white, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }

  void _sendKey(int keyCode) {
    // ADB key event — şimdilik placeholder
    // Sonra androidtvremote2 protokolü eklenecek
    print('[KEY] $keyCode');
  }
}
