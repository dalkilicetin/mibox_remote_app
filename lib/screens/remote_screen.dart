import 'package:flutter/material.dart';
import '../services/mibox_service.dart';
import 'air_mouse_screen.dart';
import 'touchpad_screen.dart';

class RemoteScreen extends StatefulWidget {
  final MiBoxService service;
  final String ip;
  const RemoteScreen({super.key, required this.service, required this.ip});

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _connected = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    // Bağlantı takibi
    widget.service.connectionStream.listen((connected) {
      if (mounted) setState(() => _connected = connected);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    widget.service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(80),
        child: SafeArea(
          child: Column(
            children: [
              // Status bar
              Container(
                color: const Color(0xFF12122a),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      _connected ? Icons.wifi : Icons.wifi_off,
                      color: _connected ? const Color(0xFF4ade80) : Colors.red,
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _connected ? '✓ ${widget.ip}' : '✗ Bağlantı kesildi',
                      style: TextStyle(
                        color: _connected ? const Color(0xFF4ade80) : Colors.red,
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: const Icon(Icons.settings, color: Colors.grey, size: 18),
                    ),
                  ],
                ),
              ),

              // Tab bar
              TabBar(
                controller: _tabController,
                indicatorColor: const Color(0xFFe94560),
                labelColor: const Color(0xFFe94560),
                unselectedLabelColor: Colors.grey,
                tabs: const [
                  Tab(text: '🌀 Air Mouse'),
                  Tab(text: '☝️ Touchpad'),
                ],
              ),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          AirMouseScreen(service: widget.service),
          TouchpadScreen(service: widget.service),
        ],
      ),
    );
  }
}
