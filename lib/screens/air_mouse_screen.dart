import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../services/mibox_service.dart';

class AirMouseScreen extends StatefulWidget {
  final MiBoxService service;
  const AirMouseScreen({super.key, required this.service});

  @override
  State<AirMouseScreen> createState() => _AirMouseScreenState();
}

class _AirMouseScreenState extends State<AirMouseScreen> {
  StreamSubscription? _orientationSub;
  bool _airOn = false;
  String _debugText = 'Hazir';

  // Beta low-pass filter
  double _fbeta = 0;
  bool _filterInit = false;
  static const double LP = 0.5;

  // Alpha delta filtering (yaw)
  double _lastRawAlpha = 0;
  double _filteredDa = 0;
  bool _lastAlphaInit = false;
  double _lastBeta = 0;
  DateTime _lastTime = DateTime.now();

  // Hassasiyet
  double _sensitivity = 25;

  // Tap butonu
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
    // AbsoluteOrientation: yaw/pitch/roll (radyan)
    _orientationSub = absoluteOrientationEventStream().listen((event) {
      // yaw = sola/saga donme (alpha) rad
      // pitch = one/arkaya egim (beta) rad
      final rawA = event.yaw * 180 / math.pi;
      final rawB = event.pitch * 180 / math.pi;
      _onOrientation(rawA, rawB);
    });
  }

  void _onOrientation(double rawA, double rawB) {
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

    final now = DateTime.now();
    if (now.difference(_lastTime).inMilliseconds < 16) return;

    if (_lastAlphaInit) {
      // PITCH
      double db = _fbeta - _lastBeta;
      if (db > 90) db -= 180;
      if (db < -90) db += 180;

      // YAW - delta filtering
      double rawDa = _lastRawAlpha - rawA;
      if (rawDa > 180) rawDa -= 360;
      if (rawDa < -180) rawDa += 360;
      _filteredDa = LP * rawDa + (1 - LP) * _filteredDa;
      double da = _filteredDa;

      if (db.abs() < 0.3) db = 0;
      if (da.abs() < 0.05) da = 0;

      if (db != 0 || da != 0) {
        final sens = _sensitivity / 25;
        final speed = math.sqrt(db * db + da * da);
        final boost = speed > 3 ? 1.0 + (speed - 3) * 0.3 : 1.0;
        final dx = (da * boost * sens * 25).round();
        final dy = (db * boost * sens * -25).round();
        if (dx != 0 || dy != 0) widget.service.moveCursor(dx, dy);

        if (mounted) {
          setState(() => _debugText =
              'pitch:${db.toStringAsFixed(2)} yaw:${da.toStringAsFixed(2)}${boost > 1 ? ' x${boost.toStringAsFixed(1)}' : ''}');
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
    widget.service.sendKey(code);
    HapticFeedback.lightImpact();
  }

  @override
  void dispose() {
    _orientationSub?.cancel();
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
                  color: Color(0xFF4ade80), fontSize: 11, fontFamily: 'monospace')),
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
                backgroundColor:
                    _airOn ? const Color(0xFFe94560) : const Color(0xFF16213e),
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

        // TIKLA + scrollbar
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
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
                          widget.service.sendKey(23);
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

                // Swipe scrollbar
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
                      border: Border.all(color: const Color(0xFF0f3460), width: 2),
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

        // Hassasiyet
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
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
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
              border:
                  Border(top: BorderSide(color: Color(0xFF0f3460), width: 2)),
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
                  style: const TextStyle(color: Colors.white, fontSize: 16),
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
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Gonder',
                            style:
                                TextStyle(color: Colors.white, fontSize: 16)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => widget.service.sendKey(67),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF0f3460)),
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
                        side: const BorderSide(color: Color(0xFF4ade80)),
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
                  child:
                      const Text('Kapat', style: TextStyle(color: Colors.grey)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
