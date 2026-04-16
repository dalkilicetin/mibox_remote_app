import 'package:flutter/material.dart';
import '../services/mibox_service.dart';

class TouchpadScreen extends StatefulWidget {
  final MiBoxService service;
  const TouchpadScreen({super.key, required this.service});

  @override
  State<TouchpadScreen> createState() => _TouchpadScreenState();
}

class _TouchpadScreenState extends State<TouchpadScreen> {
  Offset? _lastPos;
  bool _isScrollMode = false;
  Offset? _scrollLastPos;
  double _scrollAccumV = 0;
  double _scrollAccumH = 0;
  static const double SCROLL_THRESHOLD = 60;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Touchpad alanı
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Ana touchpad
                Expanded(
                  child: GestureDetector(
                    onScaleStart: (d) {
                      if (d.pointerCount == 2) {
                        _isScrollMode = true;
                        _scrollLastPos = d.localFocalPoint;
                        _scrollAccumV = 0;
                        _scrollAccumH = 0;
                      } else {
                        _isScrollMode = false;
                        _lastPos = d.localFocalPoint;
                      }
                    },
                    onScaleUpdate: (d) {
                      if (_isScrollMode) {
                        final dy = d.localFocalPoint.dy - (_scrollLastPos?.dy ?? d.localFocalPoint.dy);
                        final dx = d.localFocalPoint.dx - (_scrollLastPos?.dx ?? d.localFocalPoint.dx);
                        _scrollLastPos = d.localFocalPoint;
                        _scrollAccumV += dy;
                        _scrollAccumH += dx;
                        if (_scrollAccumV.abs() >= SCROLL_THRESHOLD) {
                          _sendScroll('v', _scrollAccumV > 0 ? -1 : 1);
                          _scrollAccumV = 0;
                        }
                        if (_scrollAccumH.abs() >= SCROLL_THRESHOLD) {
                          _sendScroll('h', _scrollAccumH > 0 ? -1 : 1);
                          _scrollAccumH = 0;
                        }
                      } else {
                        if (_lastPos == null) return;
                        final dx = (d.localFocalPoint.dx - _lastPos!.dx) * 3;
                        final dy = (d.localFocalPoint.dy - _lastPos!.dy) * 3;
                        _lastPos = d.localFocalPoint;
                        widget.service.moveCursor(dx.round(), dy.round());
                      }
                    },
                    onScaleEnd: (_) {
                      _lastPos = null;
                      _scrollLastPos = null;
                      _isScrollMode = false;
                    },
                    onDoubleTap: () => widget.service.tap(),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF0d1117),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(16),
                          bottomLeft: Radius.circular(16),
                        ),
                        border: Border.all(color: const Color(0xFF0f3460), width: 2),
                      ),
                      child: const Center(
                        child: Text(
                          'Sürükle\n2 parmak = Scroll\nÇift tık = Tıkla',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFF333355), fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ),

                // Dikey scroll bar
                Container(
                  width: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0d1117),
                    borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(16),
                      bottomRight: Radius.circular(16),
                    ),
                    border: Border.all(color: const Color(0xFF0f3460), width: 2),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      GestureDetector(
                        onTapDown: (_) => _sendScroll('v', -1),
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.keyboard_arrow_up, color: Colors.grey, size: 20),
                        ),
                      ),
                      Container(width: 4, height: 40, color: const Color(0xFF0f3460)),
                      GestureDetector(
                        onTapDown: (_) => _sendScroll('v', 1),
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.keyboard_arrow_down, color: Colors.grey, size: 20),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // Yatay scroll bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Container(
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFF0d1117),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF0f3460), width: 2),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                GestureDetector(
                  onTapDown: (_) => _sendScroll('h', -1),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.keyboard_arrow_left, color: Colors.grey, size: 20),
                  ),
                ),
                Container(height: 4, width: 60, color: const Color(0xFF0f3460)),
                GestureDetector(
                  onTapDown: (_) => _sendScroll('h', 1),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.keyboard_arrow_right, color: Colors.grey, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),

        // Tıkla butonu
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: GestureDetector(
            onTapDown: (_) => widget.service.tap(),
            child: Container(
              width: double.infinity,
              height: 52,
              decoration: BoxDecoration(
                color: const Color(0xFF1a3a1a),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF4ade80)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.mouse, color: Color(0xFF4ade80)),
                  SizedBox(width: 8),
                  Text('Tıkla', style: TextStyle(color: Color(0xFF4ade80), fontSize: 15)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),

        // Butonlar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _btn(Icons.arrow_back, 'Geri', () => _sendKey(4)),
              const SizedBox(width: 8),
              _btn(Icons.home, '', () => _sendKey(3)),
              const SizedBox(width: 8),
              _btn(Icons.play_arrow, '', () => _sendKey(85)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _btn(Icons.volume_up, '', () => _sendKey(24)),
              const SizedBox(width: 8),
              _btn(Icons.volume_down, '', () => _sendKey(25)),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _btn(IconData icon, String label, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTapDown: (_) => onTap(),
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            color: const Color(0xFF16213e),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF0f3460)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 20),
              if (label.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _sendScroll(String axis, int direction) {
    // DPAD ile scroll
    if (axis == 'v') {
      _sendKey(direction > 0 ? 20 : 19); // down/up
    } else {
      _sendKey(direction > 0 ? 21 : 22); // left/right
    }
  }

  void _sendKey(int keyCode) {
    print('[KEY] $keyCode');
  }
}
