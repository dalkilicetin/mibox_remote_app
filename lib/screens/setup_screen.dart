import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/mibox_service.dart';
import 'remote_screen.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _ipController = TextEditingController(text: '192.168.1.');
  bool _connecting = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _loadSavedIp();
  }

  Future<void> _loadSavedIp() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString('mibox_ip');
    if (ip != null) {
      _ipController.text = ip;
    }
  }

  Future<void> _connect() async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;

    setState(() {
      _connecting = true;
      _status = 'Bağlanıyor...';
    });

    final service = MiBoxService();
    final ok = await service.connect(ip);

    if (ok) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('mibox_ip', ip);

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => RemoteScreen(service: service, ip: ip),
          ),
        );
      }
    } else {
      setState(() {
        _connecting = false;
        _status = 'Bağlanamadı! IP doğru mu?\nAirCursor APK çalışıyor mu?';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.tv, color: Color(0xFFe94560), size: 64),
              const SizedBox(height: 16),
              const Text(
                'Mi Box Remote',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Mi Box IP adresini girin',
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _ipController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white, fontSize: 18),
                decoration: InputDecoration(
                  labelText: 'Mi Box IP',
                  labelStyle: const TextStyle(color: Colors.grey),
                  hintText: '192.168.1.xxx',
                  hintStyle: const TextStyle(color: Colors.grey),
                  filled: true,
                  fillColor: const Color(0xFF0f3460),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: const Icon(Icons.wifi, color: Color(0xFFe94560)),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Mi Box Settings > About > Network',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _connecting ? null : _connect,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFe94560),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _connecting
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text(
                          'Bağlan',
                          style: TextStyle(fontSize: 18, color: Colors.white),
                        ),
                ),
              ),
              if (_status.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _status.contains('Bağlanamadı')
                        ? Colors.redAccent
                        : Colors.greenAccent,
                    fontSize: 14,
                  ),
                ),
              ],
              const SizedBox(height: 32),
              const Text(
                '⚠️ Mi Box\'ta AirCursor APK çalışıyor olmalı',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
