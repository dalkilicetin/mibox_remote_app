import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_compass/flutter_compass.dart';
import '../services/mibox_service.dart';
import '../services/atv_remote_service.dart';

class AirMouseScreen extends StatefulWidget {
  final MiBoxService service;
  final AtvRemoteService atv;
  const AirMouseScreen({super.key, required this.service, required this.atv});

  @override
  State<AirMouseScreen> createState() => _AirMouseScreenState();
}

class _AirMouseScreenState extends State<AirMouseScreen> {
  StreamSubscription? _accelSub;
  StreamSubscription? _compassSub;

  bool _airOn = false;
  String _debugText = 'Hazir';

  // Web app ile birebir ayni degiskenler
  // LP = 0.5 (web appteki gibi)
  static const double LP = 0.5;

  // beta (pitch) low-pass filter
  double _fbeta = 0;
  bool _filterInit = false;

  // alpha (yaw) - delta filtering
  double _lastRawAlpha = 0;
  double _filteredDa = 0;
  bool _lastAlphaInit = false;

  // Son degerler
  double _lastBeta = 0;
  DateTime _lastTime = DateTime.now();

  // Anlık ham degerler (sensor'dan geliyor)
  double _rawAlpha = 0; // compass'tan (0-360)
  double _rawBeta = 0;  // accelerometer'dan

  // Hassasiyet (web appteki sens slider gibi)
  double _sensitivity = 25;

  // Tap butonu - web appteki gibi
  double _tapStartX = 0, _tapStartY = 0;
  double _tapLastX = 0, _tapLastY = 0;
  DateTime _tapStartTime = DateTime.now();
  double _tapAccumV = 0, _tapAccumH = 0;
  static const double TAP_MAX_MOVE = 12;
  static const int TAP_MAX_MS = 250;
  static const double SCROLL_THRESHOLD = 65;

  // Swipe scrollbar
  double _swipeAccum = 0;
  static const double SWIPE_THRESHOLD = 40;
  bool _swipeCooldown = false;

  Timer? _toggleTimer;

  // Klavye
  final TextEditingController _kbdCtrl = TextEditingController();
  bool _kbdVisible = false;

  @override
  void initState() {
    super.initState();
    _startSensors();
  }

  void _startSensors() {
    // PITCH: accelerometer'dan beta hesapla
    // web appteki e.beta gibi - telefon dik tutulurken ileri/geri egim
    _accelSub = accelerometerEventStream().listen((event) {
      // Beta: telefon ne kadar one/arkaya egilmis
      // atan2(y, sqrt(x^2+z^2)) * 180/pi - beta benzeri
      final beta = math.atan2(
        event.y,
        math.sqrt(event.x * event.x + event.z * event.z)
      ) * 180 / math.pi;
      _rawBeta = beta;
      _onGyro(_rawAlpha, _rawBeta);
    });

    // YAW: compass'tan alpha (0-360 derece, web appteki alpha gibi)
    _compassSub = FlutterCompass.events?.listen((event) {
      if (event.heading != null) {
        // compass 0-360 veriyor, web appteki alpha gibi
        _rawAlpha = (event.heading! + 360) % 360;
      }
    });
  }

  // Web app'teki onGyro fonksiyonu ile BIREBIR AYNI mantik
  void _onGyro(double rawA, double rawB) {
    // Beta icin low-pass filter
    if (!_filterInit) {
      _fbeta = rawB;
      _filterInit = true;
    }
    _fbeta = LP * rawB + (1 - LP) * _fbeta;

    if (!_airOn) {
      if (mounted) {
        setState(() => _debugText =
            'pitch:${_fbeta.toStringAsFixed(1)} yaw:${rawA.toStringAsFixed(1)}');
      }
      _lastBeta = _fbeta;
      _lastRawAlpha = rawA;
      _lastAlphaInit = true;
      return;
    }

    // 16ms rate limit (web appteki gibi)
    final now = DateTime.now();
    if (now.difference(_lastTime).inMilliseconds < 16) return;

    if (_lastAlphaInit) {
      // PITCH: beta degisimi
      double db = _fbeta - _lastBeta;
      if (db > 90) db -= 180;
      if (db < -90) db += 180;

      // YAW: delta filtering - circular filtering problemi cozumu
      // Web appteki gibi: rawDa = lastRawAlpha - rawA (wrap-around fix)
      double rawDa = _lastRawAlpha - rawA;
      if (rawDa > 180) rawDa -= 360;
      if (rawDa < -180) rawDa += 360;
      _filteredDa = LP * rawDa + (1 - LP) * _filteredDa;
      double da = _filteredDa;

      // Deadzone - web appteki gibi
      if (db.abs() < 0.3) db = 0;
      if (da.abs() < 0.05) da = 0;

      if (db != 0 || da != 0) {
        // Dinamik hassasiyet - web appteki gibi
        final sens = _sensitivity;
        final speed = math.sqrt(db * db + da * da);
        final boost = speed > 3 ? 1.0 + (speed - 3) * 0.3 : 1.0;
        final finalDb = db * sens / 25 * boost;
        final finalDa = da * boost;

        // Piksel hareketi - move komutu gonder
        final dx = (finalDa * 25).round();
        final dy = (finalDb * -25).round();
        if (dx != 0 || dy != 0) {
          widget.service.moveCursor(dx, dy);
        }

        if (mounted) {
          setState(() => _debugText =
              'pitch:${db.toStringAsFixed(2)} yaw:${da.toStringAsFixed(2)}'
              '${boost > 1 ? ' x${boost.toStringAsFixed(1)}' : ''}');
        }
      }
    }

    _lastBeta = _fbeta;
    _lastRawAlpha = rawA;
    _lastAlphaInit = true;
    _lastTime = now;
  }

  void _toggleAir() {
    setState(() => _airOn = !_airOn);
    // Reset - web appteki toggleAir gibi
    _filterInit = false;
    _lastAlphaInit = false;
    _filteredDa = 0;

    _toggleTimer?.cancel();
    _toggleTimer = Timer(const Duration(milliseconds: 300), () {
      if (_airOn) {
        widget.service.showCursor();
      } else {
        widget.service.hideCursor();
      }
    });
  }

  void _sendSwipe(int direction) {
    if (_swipeCooldown) return;
    final cx = widget.service.cursorX;
    final cy = widget.service.cursorY;
    final y2 = (cy - 150 * direction).clamp(50, MiBoxService.SCREEN_H - 50);
    widget.service.sendSwipe(x1: cx, y1: cy, x2: cx, y2: y2, duration: 100);
    widget.service.setScrollMode(1);
    _swipeCooldown = true;
    Timer(const Duration(milliseconds: 200), () => _swipeCooldown = false);
  }

  void _sendKey(int code) {
    if (widget.atv.isConnected) {
      widget.atv.sendKey(code);
    } else {
      widget.service.sendKey(code);
    }
    HapticFeedback.lightImpact();
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _compassSub?.cancel();
    _toggleTimer?.cancel();
    _kbdCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        _buildMain(),
        if (_kbdVisible) _buildKbdPopup(),
      ],
    );
  }

  Widget _buildMain() {
    return Column(
      children: [
        // Debug
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              color: const Color(0xFF0a0a1a),
              borderRadius: BorderRadius.circular(10)),
          child: Text(_debugText,
              style: const TextStyle(
                  color: Color(0xFF4ade80),
                  fontSize: 11,
                  fontFamily: 'monospace')),
        ),
        const SizedBox(height: 8),

        // Mod toggle
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
                padding: const EdgeInsets.symmetric(vertical: 11),
              ),
              child: Text(
                _airOn ? 'Air Modu' : 'Kumanda Modu',
                style: TextStyle(
                    color: _airOn ? Colors.white : const Color(0xFFe94560),
                    fontSize: 14),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),

        // TIKLA + swipe scrollbar
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                // TIKLA butonu - web appteki gibi
                Expanded(
                  child: GestureDetector(
                    onPanStart: (d) {
                      _tapStartX = _tapLastX = d.localPosition.dx;
                      _tapStartY = _tapLastY = d.localPosition.dy;
                      _tapStartTime = DateTime.now();
                      _tapAccumV = 0;
                      _tapAccumH = 0;
                    },
                    onPanUpdate: (d) {
                      final dx = d.localPosition.dx - _tapLastX;
                      final dy = d.localPosition.dy - _tapLastY;
                      _tapLastX = d.localPosition.dx;
                      _tapLastY = d.localPosition.dy;
                      _tapAccumV += dy;
                      _tapAccumH += dx;
                      if (_tapAccumV.abs() >= SCROLL_THRESHOLD) {
                        widget.service.sendKey(_tapAccumV > 0 ? 20 : 19);
                        widget.service.setScrollMode(1);
                        _tapAccumV = 0;
                      }
                      if (_tapAccumH.abs() >= SCROLL_THRESHOLD) {
                        widget.service.sendKey(_tapAccumH > 0 ? 22 : 21);
                        widget.service.setScrollMode(2);
                        _tapAccumH = 0;
                      }
                    },
                    onPanEnd: (_) {
                      final moved = math.sqrt(
                          math.pow(_tapLastX - _tapStartX, 2) +
                              math.pow(_tapLastY - _tapStartY, 2));
                      final elapsed = DateTime.now()
                          .difference(_tapStartTime)
                          .inMilliseconds;
                      if (moved < TAP_MAX_MOVE && elapsed < TAP_MAX_MS) {
                        if (_airOn) {
                          widget.service.tap();
                        } else {
                          widget.service.sendKey(23); // DPAD_CENTER
                        }
                        HapticFeedback.lightImpact();
                      }
                      _tapAccumV = 0;
                      _tapAccumH = 0;
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFe94560),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Center(
                        child: Text('TIKLA',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Swipe scrollbar (browser icin)
                GestureDetector(
                  onPanStart: (_) => _swipeAccum = 0,
                  onPanUpdate: (d) {
                    _swipeAccum += d.delta.dy;
                    if (_swipeAccum.abs() >= SWIPE_THRESHOLD) {
                      _sendSwipe(_swipeAccum > 0 ? -1 : 1);
                      _swipeAccum = 0;
                    }
                  },
                  onPanEnd: (_) => _swipeAccum = 0,
                  child: Container(
                    width: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0d1117),
                      borderRadius: BorderRadius.circular(16),
                      border:
                          Border.all(color: const Color(0xFF0f3460), width: 2),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        GestureDetector(
                          onTapDown: (_) => _sendSwipe(1),
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.keyboard_arrow_up,
                                color: Color(0xFFe94560), size: 20),
                          ),
                        ),
                        Container(
                            width: 4,
                            height: 40,
                            color: const Color(0xFF0f3460)),
                        GestureDetector(
                          onTapDown: (_) => _sendSwipe(-1),
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.keyboard_arrow_down,
                                color: Color(0xFFe94560), size: 20),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),

        // Butonlar
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
        const SizedBox(height: 8),

        // Klavye butonu
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => setState(() => _kbdVisible = true),
              icon: const Icon(Icons.keyboard, color: Color(0xFF4ade80)),
              label: const Text('Klavye',
                  style: TextStyle(color: Color(0xFF4ade80))),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF4ade80)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),

        // Hassasiyet slider
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: const Color(0xFF0a0a1a),
                borderRadius: BorderRadius.circular(10)),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Hassasiyet',
                        style: TextStyle(color: Colors.grey, fontSize: 12)),
                    Text(_sensitivity.round().toString(),
                        style: const TextStyle(
                            color: Color(0xFFe94560),
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
                Slider(
                  value: _sensitivity,
                  min: 5,
                  max: 150,
                  activeColor: const Color(0xFFe94560),
                  onChanged: (v) => setState(() => _sensitivity = v),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _airBtn(IconData icon, String label, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTapDown: (_) => onTap(),
        child: Container(
          height: 55,
          decoration: BoxDecoration(
            color: const Color(0xFF16213e),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF0f3460)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 6),
              Text(label,
                  style:
                      const TextStyle(color: Colors.white, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKbdPopup() {
    return GestureDetector(
      onTap: () => setState(() => _kbdVisible = false),
      child: Container(
        color: Colors.black54,
        alignment: Alignment.bottomCenter,
        child: GestureDetector(
          onTap: () {},
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xFF12122a),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(
                  top: BorderSide(color: Color(0xFF0f3460), width: 2)),
            ),
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('TV Klavyesi',
                    style: TextStyle(color: Colors.grey, fontSize: 14)),
                const SizedBox(height: 12),
                TextField(
                  controller: _kbdCtrl,
                  autofocus: true,
                  style:
                      const TextStyle(color: Colors.white, fontSize: 16),
                  decoration: InputDecoration(
                    hintText: 'Yazmak istediginizi girin...',
                    hintStyle: const TextStyle(color: Colors.grey),
                    filled: true,
                    fillColor: const Color(0xFF0d1117),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide:
                            const BorderSide(color: Color(0xFFe94560))),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          final text = _kbdCtrl.text;
                          if (text.isEmpty) return;
                          widget.service.sendText(text);
                          _kbdCtrl.clear();
                          HapticFeedback.mediumImpact();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFe94560),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Gonder',
                            style: TextStyle(
                                color: Colors.white, fontSize: 16)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => widget.service.sendKey(67),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(
                            color: Color(0xFF0f3460)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(
                            vertical: 14, horizontal: 16),
                      ),
                      child: const Icon(Icons.backspace,
                          color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => widget.service.sendKey(66),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(
                            color: Color(0xFF4ade80)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(
                            vertical: 14, horizontal: 16),
                      ),
                      child: const Icon(Icons.keyboard_return,
                          color: Color(0xFF4ade80), size: 20),
                    ),
                  ],
                ),
                TextButton(
                  onPressed: () => setState(() => _kbdVisible = false),
                  child: const Text('Kapat',
                      style: TextStyle(color: Colors.grey)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
