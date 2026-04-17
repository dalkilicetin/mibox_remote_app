import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/mibox_service.dart';
import '../services/atv_remote_service.dart';

class TouchpadScreen extends StatefulWidget {
  final MiBoxService service;
  final AtvRemoteService atv;
  const TouchpadScreen({super.key, required this.service, required this.atv});

  @override
  State<TouchpadScreen> createState() => _TouchpadScreenState();
}

class _TouchpadScreenState extends State<TouchpadScreen> {
  // Ana touchpad
  Offset? _lastPos;
  bool _isScrollMode = false;
  Offset? _scrollLastPos;
  double _scrollAccumV = 0;
  double _scrollAccumH = 0;
  static const double SCROLL_THRESHOLD = 60;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);

  // Swipe scrollbar (browser icin)
  double _swipeAccum = 0;
  static const double SWIPE_THRESHOLD = 40;
  bool _swipeCooldown = false;

  // Klavye
  final TextEditingController _kbdCtrl = TextEditingController();
  bool _kbdVisible = false;

  void _sendKey(int keyCode) {
    if (widget.atv.isConnected) {
      widget.atv.sendKey(keyCode);
    } else {
      widget.service.sendKey(keyCode);
    }
    HapticFeedback.lightImpact();
  }

  void _sendSwipe(int direction) {
    if (_swipeCooldown) return;
    final cx = widget.service.cursorX;
    final cy = widget.service.cursorY;
    final y2 = (cy - 150 * direction).clamp(50, MiBoxService.SCREEN_H - 50);
    widget.service.sendSwipe(x1: cx, y1: cy, x2: cx, y2: y2, duration: 100);
    widget.service.setScrollMode(1);
    _swipeCooldown = true;
    Future.delayed(const Duration(milliseconds: 200), () => _swipeCooldown = false);
  }

  @override
  void dispose() {
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
        // Touchpad + scrollbar
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
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
                        final dy = d.localFocalPoint.dy -
                            (_scrollLastPos?.dy ?? d.localFocalPoint.dy);
                        final dx = d.localFocalPoint.dx -
                            (_scrollLastPos?.dx ?? d.localFocalPoint.dx);
                        _scrollLastPos = d.localFocalPoint;
                        _scrollAccumV += dy;
                        _scrollAccumH += dx;
                        if (_scrollAccumV.abs() >= SCROLL_THRESHOLD) {
                          _sendKey(_scrollAccumV > 0 ? 20 : 19);
                          widget.service.setScrollMode(1);
                          _scrollAccumV = 0;
                        }
                        if (_scrollAccumH.abs() >= SCROLL_THRESHOLD) {
                          _sendKey(_scrollAccumH > 0 ? 22 : 21);
                          widget.service.setScrollMode(2);
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
                    onDoubleTap: () {
                      widget.service.tap();
                      HapticFeedback.lightImpact();
                    },
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
                          'Surukle\n2 parmak = Scroll\nCift tik = Tikla',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFF333355), fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ),

                // Dikey scrollbar (DPAD)
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
                        onTapDown: (_) => _sendKey(19),
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.keyboard_arrow_up,
                              color: Colors.grey, size: 20),
                        ),
                      ),
                      Container(width: 4, height: 40, color: const Color(0xFF0f3460)),
                      GestureDetector(
                        onTapDown: (_) => _sendKey(20),
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.keyboard_arrow_down,
                              color: Colors.grey, size: 20),
                        ),
                      ),
                    ],
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
                      border: Border.all(color: const Color(0xFF4ade80), width: 2),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        GestureDetector(
                          onTapDown: (_) => _sendSwipe(1),
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.keyboard_arrow_up,
                                color: Color(0xFF4ade80), size: 20),
                          ),
                        ),
                        const Text('S', style: TextStyle(color: Color(0xFF4ade80), fontSize: 9)),
                        Container(width: 4, height: 30, color: const Color(0xFF4ade80)),
                        const Text('W', style: TextStyle(color: Color(0xFF4ade80), fontSize: 9)),
                        GestureDetector(
                          onTapDown: (_) => _sendSwipe(-1),
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.keyboard_arrow_down,
                                color: Color(0xFF4ade80), size: 20),
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

        // Yatay scrollbar
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
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
                  onTapDown: (_) => _sendKey(21),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.keyboard_arrow_left, color: Colors.grey, size: 20),
                  ),
                ),
                Container(height: 4, width: 60, color: const Color(0xFF0f3460)),
                GestureDetector(
                  onTapDown: (_) => _sendKey(22),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.keyboard_arrow_right, color: Colors.grey, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),

        // Tikla
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: GestureDetector(
            onTapDown: (_) {
              widget.service.tap();
              HapticFeedback.lightImpact();
            },
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
                  Text('Tikla', style: TextStyle(color: Color(0xFF4ade80), fontSize: 15)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),

        // Klavye butonu
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => setState(() => _kbdVisible = true),
              icon: const Icon(Icons.keyboard, color: Color(0xFF4ade80)),
              label: const Text('Klavye', style: TextStyle(color: Color(0xFF4ade80))),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF4ade80)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),

        // Butonlar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _btn(Icons.arrow_back, 'Geri', () => _sendKey(4)),
              const SizedBox(width: 8),
              _btn(Icons.home, 'Home', () => _sendKey(3)),
              const SizedBox(width: 8),
              _btn(Icons.play_arrow, 'Play', () => _sendKey(85)),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _btn(Icons.volume_up, 'Ses+', () => _sendKey(24)),
              const SizedBox(width: 8),
              _btn(Icons.volume_down, 'Ses-', () => _sendKey(25)),
            ],
          ),
        ),
        const SizedBox(height: 8),
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
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
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
              border: Border(top: BorderSide(color: Color(0xFF0f3460), width: 2)),
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
                        borderSide: const BorderSide(color: Color(0xFFe94560))),
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
                            style: TextStyle(color: Colors.white, fontSize: 16)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => widget.service.sendKey(67),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF0f3460)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                      ),
                      child: const Icon(Icons.backspace, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => widget.service.sendKey(66),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF4ade80)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                      ),
                      child: const Icon(Icons.keyboard_return,
                          color: Color(0xFF4ade80), size: 20),
                    ),
                  ],
                ),
                TextButton(
                  onPressed: () => setState(() => _kbdVisible = false),
                  child: const Text('Kapat', style: TextStyle(color: Colors.grey)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
