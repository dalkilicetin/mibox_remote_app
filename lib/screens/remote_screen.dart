import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/mibox_service.dart';
import '../services/atv_remote_service.dart';
import 'air_mouse_screen.dart';
import 'touchpad_screen.dart';

class RemoteScreen extends StatefulWidget {
  final MiBoxService? service; // null = APK yok, sadece ATV mod
  final String ip;
  final int remotePort;
  final int pairingPort;

  const RemoteScreen({
    super.key,
    required this.service,
    required this.ip,
    this.remotePort  = 6466,
    this.pairingPort = 6467,
  });

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _apkConnected = false;
  final AtvRemoteService _atv = AtvRemoteService();
  bool _atvConnected = false;
  final List<String> _atvLogs = [];
  String _certHash = '';

  bool get _hasApk => widget.service != null;

  @override
  void initState() {
    super.initState();
    // APK varsa 2 tab (Air Mouse + Touchpad), yoksa 1 tab (D-Pad)
    _tabController = TabController(length: _hasApk ? 3 : 2, vsync: this);

    if (_hasApk) {
      _apkConnected = widget.service!.isConnected;
      widget.service!.connectionStream.listen((connected) {
        if (mounted) setState(() => _apkConnected = connected);
      });
    }

    _atv.connectionStream.listen((connected) {
      print('[ATV-UI] stream event: connected=$connected, mounted=$mounted');
      if (mounted) setState(() {
        _atvConnected = connected;
        _addLog('Stream: ATV ${connected ? "BAĞLANDI ✓" : "KESİLDİ ✗"}');
      });
    });

    _initAtv();
  }

  Future<void> _initAtv() async {
    _atv.onLog = (msg) { if (mounted) _addLog(msg); };
    _addLog('ATV bağlanılıyor: ${widget.ip}:${widget.remotePort}');
    try {
      final prefs = await SharedPreferences.getInstance();
      final cert = prefs.getString('atv_cert_${widget.ip}')
                ?? prefs.getString('mibox_cert_${widget.ip}')
                ?? prefs.getString('mibox_cert') ?? '';
      final key  = prefs.getString('atv_key_${widget.ip}')
                ?? prefs.getString('mibox_key_${widget.ip}')
                ?? prefs.getString('mibox_key') ?? '';
      if (cert.isEmpty || key.isEmpty) {
        _addLog('HATA: Sertifika bulunamadı! Yeniden eşleştir.');
        return;
      }
      _addLog('Sertifika bulundu (${cert.length}b), bağlanılıyor...');
      _addLog('cert[0]: ' + cert.split('\n').first);
      _addLog('cert son: ' + cert.trimRight().split('\n').last);
      _addLog('cert hash: ' + cert.hashCode.toString());
      _addLog('key[0]: ' + key.split('\n').first);
      _addLog('certLines: ' + cert.split('\n').length.toString());
      // Hash karşılaştırması — pairing ile remote aynı sertifika mı?
      final savedHash = cert.hashCode;
      _addLog('Remote cert hash: $savedHash (${cert.split("\n").length} satır)');
      _addLog('Remote key[0]: ${key.split("\n").first}');
      _atv.setCertificates(cert, key);
      final ok = await _atv.connect(widget.ip, remotePort: widget.remotePort);
      _addLog(ok ? 'ATV bağlandı ✓' : 'ATV bağlantısı başarısız!');
      // Race condition kontrolü: connect true döndü ama stream gelmedi mi?
      if (ok && mounted) {
        await Future.delayed(const Duration(milliseconds: 200));
        _addLog('200ms sonra isConnected: \${_atv.isConnected}, _atvConnected: \$_atvConnected');
        if (_atv.isConnected && !_atvConnected) {
          _addLog('RACE CONDITION! Manuel setState yapılıyor...');
          setState(() => _atvConnected = true);
        }
      }
    } catch (e) {
      _addLog('Init hatası: $e');
      print('[ATV] Init error: $e');
    }
  }

  void _addLog(String msg) {
    print('[ATV-UI] $msg');
    if (mounted) setState(() {
      _atvLogs.add('[${DateTime.now().second}s] $msg');
      if (_atvLogs.length > 20) _atvLogs.removeAt(0);
      // cert hash'i yakala — kaybolmasın
      if (msg.contains('cert hash:') || msg.contains('Remote cert hash')) {
        _certHash = msg;
      }
    });
  }



  @override
  void dispose() {
    _tabController.dispose();
    widget.service?.dispose();
    _atv.dispose();
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
                    // APK durumu
                    if (_hasApk) ...[
                      Icon(Icons.mouse,
                          color: _apkConnected ? const Color(0xFF4ade80) : Colors.red,
                          size: 14),
                      const SizedBox(width: 4),
                      Text(_apkConnected ? 'Cursor' : 'Cursor yok',
                          style: TextStyle(
                              color: _apkConnected ? const Color(0xFF4ade80) : Colors.red,
                              fontSize: 11)),
                      const SizedBox(width: 12),
                    ],
                    // ATV Remote durumu
                    Icon(Icons.tv,
                        color: _atvConnected ? const Color(0xFF4ade80) : Colors.grey,
                        size: 14),
                    const SizedBox(width: 4),
                    Text(_atvConnected ? 'TV Remote' : 'TV bağlantısı yok',
                        style: TextStyle(
                            color: _atvConnected ? const Color(0xFF4ade80) : Colors.grey,
                            fontSize: 11)),
                    const Spacer(),
                    if (_certHash.isNotEmpty)
                      GestureDetector(
                        onTap: () {},
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0f3460),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _certHash.length > 20 ? _certHash.substring(0, 20) + '...' : _certHash,
                            style: const TextStyle(color: Color(0xFF4ade80), fontSize: 9, fontFamily: 'monospace'),
                          ),
                        ),
                      ),
                    const SizedBox(width: 4),
                    Text(widget.ip,
                        style: const TextStyle(color: Colors.grey, fontSize: 11)),
                    const SizedBox(width: 8),

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
                tabs: [
                  if (_hasApk) const Tab(text: 'Air Mouse'),
                  if (_hasApk) const Tab(text: 'Touchpad'),
                  if (!_hasApk) const Tab(text: 'Kumanda'),
                  const Tab(text: '🐛 Debug'),
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
          if (_hasApk) AirMouseScreen(service: widget.service!, atv: _atv),
          if (_hasApk) TouchpadScreen(service: widget.service!, atv: _atv),
          if (!_hasApk) _DpadScreen(atv: _atv),
          _DebugScreen(
            logs: _atvLogs,
            onClear: () => setState(() => _atvLogs.clear()),
            onReconnect: () { _atvLogs.clear(); _initAtv(); },
          ),
        ],
      ),
    );
  }
}

// ── D-Pad ekranı — APK olmadan sadece ATV tuş komutları ─────────────────────
class _DpadScreen extends StatelessWidget {
  final AtvRemoteService atv;
  const _DpadScreen({required this.atv});

  void _key(int code) => atv.sendKey(code);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Bilgi notu
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0f3460),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.grey, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'AirCursor APK kurulu değil. Cursor ve dokunmatik pad kullanmak için APK\'yı TV\'ye kurun.',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Ses kontrolleri
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _btn(Icons.volume_down, () => _key(25)),
              const SizedBox(width: 16),
              _btn(Icons.volume_up, () => _key(24)),
            ],
          ),
          const SizedBox(height: 24),

          // D-Pad
          Column(
            children: [
              _btn(Icons.keyboard_arrow_up, () => _key(19)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _btn(Icons.keyboard_arrow_left, () => _key(21)),
                  const SizedBox(width: 8),
                  _centerBtn(),
                  const SizedBox(width: 8),
                  _btn(Icons.keyboard_arrow_right, () => _key(22)),
                ],
              ),
              const SizedBox(height: 8),
              _btn(Icons.keyboard_arrow_down, () => _key(20)),
            ],
          ),
          const SizedBox(height: 24),

          // Back / Home / Play
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _labelBtn(Icons.arrow_back, 'Geri', () => _key(4)),
              const SizedBox(width: 16),
              _labelBtn(Icons.home, 'Ana Sayfa', () => _key(3)),
              const SizedBox(width: 16),
              _labelBtn(Icons.play_arrow, 'Play', () => _key(85)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _btn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTapDown: (_) => onTap(),
      child: Container(
        width: 64, height: 64,
        decoration: BoxDecoration(
          color: const Color(0xFF16213e),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF0f3460)),
        ),
        child: Icon(icon, color: Colors.white, size: 28),
      ),
    );
  }

  Widget _centerBtn() {
    return GestureDetector(
      onTapDown: (_) => atv.sendKey(23),
      child: Container(
        width: 64, height: 64,
        decoration: BoxDecoration(
          color: const Color(0xFFe94560),
          borderRadius: BorderRadius.circular(32),
        ),
        child: const Icon(Icons.circle, color: Colors.white, size: 20),
      ),
    );
  }

  Widget _labelBtn(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTapDown: (_) => onTap(),
      child: Container(
        width: 80, height: 64,
        decoration: BoxDecoration(
          color: const Color(0xFF16213e),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF0f3460)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: Colors.grey, fontSize: 9)),
          ],
        ),
      ),
    );
  }
}

// ── Debug Sekmesi ─────────────────────────────────────────────────────────────
class _DebugScreen extends StatelessWidget {
  final List<String> logs;
  final VoidCallback onClear;
  final VoidCallback onReconnect;

  const _DebugScreen({
    required this.logs,
    required this.onClear,
    required this.onReconnect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Kontrol butonları
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onReconnect,
                  icon: const Icon(Icons.refresh, size: 16, color: Color(0xFFe94560)),
                  label: const Text('Yeniden Bağlan', style: TextStyle(color: Color(0xFFe94560), fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFFe94560)),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: onClear,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.grey),
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Temizle', style: TextStyle(color: Colors.grey, fontSize: 12)),
              ),
            ],
          ),
        ),

        // Log listesi
        Expanded(
          child: logs.isEmpty
              ? const Center(
                  child: Text('Log yok', style: TextStyle(color: Colors.grey)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  reverse: true,
                  itemCount: logs.length,
                  itemBuilder: (_, i) {
                    final log = logs[logs.length - 1 - i];
                    Color color;
                    if (log.contains('HATA') || log.contains('KESİLDİ') || log.contains('error') || log.contains('başarısız')) {
                      color = Colors.redAccent;
                    } else if (log.contains('✓') || log.contains('BAĞLANDI') || log.contains('hash')) {
                      color = const Color(0xFF4ade80);
                    } else if (log.contains('→') || log.contains('←')) {
                      color = const Color(0xFF60a5fa);
                    } else {
                      color = Colors.grey;
                    }
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        log,
                        style: TextStyle(color: color, fontSize: 10, fontFamily: 'monospace'),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
