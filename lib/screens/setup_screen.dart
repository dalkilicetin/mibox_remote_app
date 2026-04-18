import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:basic_utils/basic_utils.dart';
import '../services/mibox_service.dart';
import '../services/atv_remote_service.dart';
import 'remote_screen.dart';

// ── Bulunan cihaz modeli ──────────────────────────────────────────────────────
class DiscoveredDevice {
  final String ip;
  final bool hasCert;
  final bool hasApk;       // AirCursor APK çalışıyor mu
  final int pairingPort;
  final int remotePort;

  const DiscoveredDevice({
    required this.ip,
    required this.hasCert,
    required this.hasApk,
    this.pairingPort = 6467,
    this.remotePort  = 6466,
  });
}

// ── Setup Screen ──────────────────────────────────────────────────────────────
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  List<DiscoveredDevice> _devices = [];
  bool _scanning = false;
  String _scanStatus = '';
  int _scanned = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  // ── Subnet discovery ────────────────────────────────────────────────────────
  Future<List<String>> _getSubnets() async {
    final subnets = <String>[];
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          final a = int.tryParse(parts[0]) ?? 0;
          final b = int.tryParse(parts[1]) ?? 0;
          String? subnet;
          if (a == 10) subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
          else if (a == 172 && b >= 16 && b <= 31) subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
          else if (a == 192 && b == 168) subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
          if (subnet != null && !subnets.contains(subnet)) subnets.add(subnet);
        }
      }
    } catch (_) {}
    return subnets;
  }

  // ── ATV port tarama (paralel) ───────────────────────────────────────────────
  static const _pairingPorts = [6467, 6468, 7676];
  static const _remotePorts  = [6466, 6468, 7675];

  Future<int?> _tryPorts(String ip, List<int> ports) async {
    final completer = Completer<int?>();
    var pending = ports.length;
    for (final port in ports) {
      Socket.connect(ip, port, timeout: const Duration(milliseconds: 600))
          .then((sock) {
        sock.destroy();
        if (!completer.isCompleted) completer.complete(port);
      }).catchError((_) {
        pending--;
        if (pending == 0 && !completer.isCompleted) completer.complete(null);
      });
    }
    return completer.future;
  }

  // ── Ana tarama ──────────────────────────────────────────────────────────────
  Future<void> _startScan() async {
    setState(() {
      _scanning = true;
      _devices = [];
      _scanStatus = 'AirCursor APK aranıyor (UDP)...';
      _scanned = 0;
      _total = 0;
    });

    final prefs = await SharedPreferences.getInstance();
    final found = <DiscoveredDevice>[];

    // 1. UDP broadcast — APK'ı hızlı bul, ama ATV portlarını yine de tara
    // (APK localhost'tan ATV portlarını doğru okuyamıyor, scan daha güvenilir)
    final udpFoundIps = <String>{};
    await MiBoxService.discoverDevices(
      timeout: const Duration(seconds: 3),
      onDeviceFound: (device) {
        udpFoundIps.add(device['ip'] as String);
      },
    );

    // 2. IP taraması — UDP bulunan IP'ler önce, sonra tüm subnet
    setState(() => _scanStatus = 'ATV portları taranıyor...');
    final subnets = await _getSubnets();
    if (subnets.isEmpty) {
      setState(() { _scanning = false; _scanStatus = 'Wi-Fi ağı bulunamadı.'; });
      return;
    }

    setState(() { _total = 254 * subnets.length; });
    const batchSize = 30;
    var totalScanned = 0;

    for (final subnet in subnets) {
      if (!mounted) return;
      setState(() => _scanStatus = 'Taranıyor: $subnet.0/24');

      for (var start = 1; start <= 254; start += batchSize) {
        if (!mounted) return;
        final end = min(start + batchSize - 1, 254);
        final futures = <Future<void>>[];

        for (var i = start; i <= end; i++) {
          final ip = '$subnet.$i';
          futures.add(() async {
            // UDP'de bulunan IP ise APK kesin var, sadece ATV portlarını tara
            final udpFound = udpFoundIps.contains(ip);

            final results = await Future.wait([
              _tryPorts(ip, _pairingPorts),
              _tryPorts(ip, _remotePorts),
              // APK port 9876 — UDP'de zaten bulunduysa atla
              udpFound
                  ? Future.value(true)
                  : Socket.connect(ip, 9876,
                          timeout: const Duration(milliseconds: 600))
                      .then((s) { s.destroy(); return true; })
                      .catchError((_) => false),
            ]);

            final pairingPort = results[0] as int?;
            final remotePort  = results[1] as int?;
            final hasApk      = results[2] as bool;

            // En az bir port açık olmalı
            if (pairingPort == null && remotePort == null && !hasApk) return;

            final hasCert = (prefs.getString('atv_cert_$ip') ?? '').isNotEmpty;
            // Scan'den gelen gerçek portları kaydet (APK'nın söylediğine değil buna güven)
            if (pairingPort != null) await prefs.setInt('atv_pairing_port_$ip', pairingPort);
            if (remotePort  != null) await prefs.setInt('atv_remote_port_$ip',  remotePort);

            if (!found.any((d) => d.ip == ip) && mounted) {
              final d = DiscoveredDevice(
                ip: ip,
                hasCert: hasCert,
                hasApk: hasApk,
                pairingPort: pairingPort ?? 6467,
                remotePort:  remotePort  ?? 6466,
              );
              found.add(d);
              setState(() => _devices = List.from(found));
            }
          }());
        }

        await Future.wait(futures);
        totalScanned += (end - start + 1);
        if (mounted) setState(() => _scanned = totalScanned);
      }
    }

    if (mounted) {
      setState(() {
        _scanning = false;
        _scanStatus = found.isEmpty
            ? 'Cihaz bulunamadı. TV açık mı?'
            : '${found.length} cihaz bulundu';
      });
    }
  }

  // ── Bağlan ─────────────────────────────────────────────────────────────────
  Future<void> _connectTo(DiscoveredDevice device) async {
    final prefs = await SharedPreferences.getInstance();
    final cert = prefs.getString('atv_cert_${device.ip}')
        ?? prefs.getString('mibox_cert_${device.ip}')
        ?? prefs.getString('mibox_cert') ?? '';
    final key = prefs.getString('atv_key_${device.ip}')
        ?? prefs.getString('mibox_key_${device.ip}')
        ?? prefs.getString('mibox_key') ?? '';

    if (cert.isNotEmpty && key.isNotEmpty) {
      await prefs.setString('atv_cert_${device.ip}', cert);
      await prefs.setString('atv_key_${device.ip}', key);
    }

    if (cert.isEmpty || key.isEmpty) {
      if (!mounted) return;
      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => PairingScreen(
          ip: device.ip, pairingPort: device.pairingPort)),
      );
      if (result == true) await _launchRemote(device);
    } else {
      await _launchRemote(device);
    }
  }

  Future<void> _launchRemote(DiscoveredDevice device) async {
    // APK varsa bağlan, yoksa null service ile sadece ATV mod
    MiBoxService? service;
    int remotePort = device.remotePort;

    if (device.hasApk) {
      service = MiBoxService();
      final ok = await service.connect(device.ip);
      if (!ok) service = null;
      // APK'dan gelen gerçek ATV portunu kullan
      if (service != null) remotePort = service.atvRemotePort;
    }

    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mibox_ip', device.ip);
    await prefs.setInt('atv_remote_port_${device.ip}', remotePort);
    await prefs.setInt('atv_pairing_port_${device.ip}', device.pairingPort);

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => RemoteScreen(
        service: service,      // null ise sadece ATV mod
        ip: device.ip,
        remotePort: remotePort,
        pairingPort: device.pairingPort,
      )),
    );
  }

  // ── Manuel IP ──────────────────────────────────────────────────────────────
  Future<void> _manualEntry() async {
    final ctrl = TextEditingController();
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('mibox_ip');
    if (saved != null) ctrl.text = saved;

    if (!mounted) return;
    final ip = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF12122a),
        title: const Text('Manuel IP Gir', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: '192.168.x.x',
            hintStyle: const TextStyle(color: Colors.grey),
            filled: true,
            fillColor: const Color(0xFF0f3460),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('İptal', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFe94560)),
            child: const Text('Bağlan', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (ip == null || ip.isEmpty) return;
    final cert = prefs.getString('atv_cert_$ip') ?? prefs.getString('mibox_cert_$ip') ?? '';
    final pairingPort = prefs.getInt('atv_pairing_port_$ip') ?? 6467;
    final remotePort  = prefs.getInt('atv_remote_port_$ip')  ?? 6466;
    // APK portunu hızlıca kontrol et
    bool hasApk = false;
    try {
      final s = await Socket.connect(ip, 9876, timeout: const Duration(seconds: 2));
      s.destroy(); hasApk = true;
    } catch (_) {}
    final device = DiscoveredDevice(
      ip: ip, hasCert: cert.isNotEmpty, hasApk: hasApk,
      pairingPort: pairingPort, remotePort: remotePort,
    );
    await _connectTo(device);
  }

  // ── UI ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 16),
              child: Column(
                children: [
                  const Icon(Icons.tv, color: Color(0xFFe94560), size: 56),
                  const SizedBox(height: 10),
                  const Text('Mi Box Remote', style: TextStyle(
                      color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text(_scanStatus, textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey, fontSize: 13)),
                ],
              ),
            ),

            if (_scanning)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      value: _total > 0 ? _scanned / _total : null,
                      backgroundColor: const Color(0xFF0f3460),
                      color: const Color(0xFFe94560),
                      minHeight: 4,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    const SizedBox(height: 4),
                    Text(_total > 0 ? '$_scanned / $_total' : '',
                        style: const TextStyle(color: Colors.grey, fontSize: 11)),
                  ],
                ),
              ),

            Expanded(
              child: _devices.isEmpty && !_scanning
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.devices_other, color: Colors.grey, size: 52),
                          SizedBox(height: 12),
                          Text('Cihaz bulunamadı',
                              style: TextStyle(color: Colors.grey, fontSize: 16)),
                          SizedBox(height: 4),
                          Text('TV açık ve aynı Wi-Fi\'da mı?',
                              style: TextStyle(color: Colors.grey, fontSize: 13)),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _devices.length,
                      itemBuilder: (_, i) {
                        final d = _devices[i];
                        return _DeviceCard(
                          device: d,
                          onTap: () => _connectTo(d),
                          onRepair: () async {
                            final prefs = await SharedPreferences.getInstance();
                            await prefs.remove('atv_cert_${d.ip}');
                            await prefs.remove('atv_key_${d.ip}');
                            await prefs.remove('mibox_cert_${d.ip}');
                            await prefs.remove('mibox_key_${d.ip}');
                            if (!mounted) return;
                            final result = await Navigator.push<bool>(
                              context,
                              MaterialPageRoute(builder: (_) =>
                                  PairingScreen(ip: d.ip, pairingPort: d.pairingPort)),
                            );
                            if (result == true) await _launchRemote(d);
                          },
                        );
                      },
                    ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _scanning ? null : _startScan,
                      icon: _scanning
                          ? const SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(
                                  color: Color(0xFFe94560), strokeWidth: 2))
                          : const Icon(Icons.refresh, color: Color(0xFFe94560)),
                      label: Text(_scanning ? 'Aranıyor...' : 'Yeniden Tara',
                          style: const TextStyle(color: Color(0xFFe94560))),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFFe94560)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _manualEntry,
                      icon: const Icon(Icons.edit, color: Colors.grey),
                      label: const Text('Manuel IP', style: TextStyle(color: Colors.grey)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.grey),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Cihaz kartı ───────────────────────────────────────────────────────────────
class _DeviceCard extends StatelessWidget {
  final DiscoveredDevice device;
  final VoidCallback onTap;
  final VoidCallback onRepair;

  const _DeviceCard({required this.device, required this.onTap, required this.onRepair});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF12122a),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: device.hasCert
              ? const Color(0xFF4ade80).withOpacity(0.5)
              : const Color(0xFF0f3460),
          width: 1.5,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 44, height: 44,
          decoration: BoxDecoration(color: const Color(0xFF0f3460),
              borderRadius: BorderRadius.circular(10)),
          child: Icon(Icons.tv,
              color: device.hasCert ? const Color(0xFF4ade80) : const Color(0xFFe94560),
              size: 24),
        ),
        title: const Text('Mi Box',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(device.ip, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 2),
            Row(
              children: [
                // Eşleştirme durumu
                Text(
                  device.hasCert ? '✓ Eşleştirildi' : 'Eşleştirilmedi',
                  style: TextStyle(
                    color: device.hasCert ? const Color(0xFF4ade80) : const Color(0xFFfbbf24),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(width: 8),
                // APK durumu
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: device.hasApk
                        ? const Color(0xFF4ade80).withOpacity(0.15)
                        : Colors.grey.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    device.hasApk ? 'APK ✓' : 'APK yok',
                    style: TextStyle(
                      color: device.hasApk ? const Color(0xFF4ade80) : Colors.grey,
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (device.hasCert)
              IconButton(
                icon: const Icon(Icons.link_off, color: Colors.grey, size: 18),
                tooltip: 'Yeniden Eşleştir',
                onPressed: onRepair,
              ),
            ElevatedButton(
              onPressed: onTap,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFe94560),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
              child: Text(device.hasCert ? 'Bağlan' : 'Eşleştir',
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

// ── Pairing Screen ────────────────────────────────────────────────────────────
class PairingScreen extends StatefulWidget {
  final String ip;
  final int pairingPort;
  const PairingScreen({super.key, required this.ip, this.pairingPort = 6467});
  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _pinController = TextEditingController();
  String _status = 'Sertifika oluşturuluyor...';
  bool _waitingPin = false;
  bool _pairing = false;
  _AtvPairingSession? _session;
  final List<String> _logs = [];

  void _log(String msg) {
    print('[PAIR] $msg');
    if (mounted) setState(() => _logs.add('[${DateTime.now().second}s] $msg'));
  }

  @override
  void initState() { super.initState(); _startPairing(); }

  static const _candidatePorts = [6467, 6468, 7676];

  Future<void> _startPairing() async {
    _logs.clear();
    try {
      _log('Sertifika oluşturuluyor...');
      setState(() => _status = 'Sertifika oluşturuluyor...');

      final portsToTry = [
        widget.pairingPort,
        ..._candidatePorts.where((p) => p != widget.pairingPort),
      ];
      _log('Denenecek portlar: $portsToTry');

      int? workingPort;
      for (final port in portsToTry) {
        _log('Port $port deneniyor...');
        setState(() => _status = 'Bağlanılıyor... (port $port)');
        _session = await _AtvPairingSession.create(widget.ip, pairingPort: port);
        final error = await _session!.connectWithLog(_log);
        if (error == null) {
          workingPort = port;
          _log('Port $port OK — PIN bekleniyor');
          break;
        } else {
          _log('Port $port hata: $error');
        }
      }

      if (workingPort != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('atv_pairing_port_${widget.ip}', workingPort);
        setState(() { _status = 'TV ekranındaki 6 haneli kodu girin:'; _waitingPin = true; });
      } else {
        setState(() => _status = 'Bağlantı kurulamadı!');
      }
    } catch (e) {
      _log('Exception: $e');
      setState(() => _status = 'Hata: $e');
    }
  }

  Future<void> _sendPin() async {
    final pin = _pinController.text.trim().toUpperCase();
    if (pin.length < 6) return;
    setState(() { _pairing = true; _status = 'Doğrulanıyor...'; });
    try {
      final ok = await _session!.sendPin(pin);
      if (ok) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('atv_cert_${widget.ip}', _session!.certPem);
        await prefs.setString('atv_key_${widget.ip}', _session!.keyPem);
        if (mounted) Navigator.pop(context, true);
      } else {
        setState(() { _pairing = false; _status = 'Yanlış kod! Tekrar deneyin:'; });
        _pinController.clear();
      }
    } catch (e) {
      setState(() { _pairing = false; _status = 'Hata: $e'; });
    }
  }

  @override
  void dispose() { _session?.dispose(); _pinController.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        backgroundColor: const Color(0xFF12122a),
        title: Text('TV Eşleştirme — ${widget.ip}',
            style: const TextStyle(color: Colors.white, fontSize: 15)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.link, color: Color(0xFFe94560), size: 64),
            const SizedBox(height: 24),
            Text(_status, textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16)),
            if (_waitingPin) ...[
              const SizedBox(height: 32),
              TextField(
                controller: _pinController,
                autofocus: true,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 32,
                    letterSpacing: 8, fontWeight: FontWeight.bold),
                maxLength: 6,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  hintText: 'XXXXXX',
                  hintStyle: const TextStyle(color: Colors.grey, fontSize: 32),
                  filled: true, fillColor: const Color(0xFF0f3460),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFe94560))),
                  counterText: '',
                ),
                onSubmitted: (_) => _sendPin(),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity, height: 52,
                child: ElevatedButton(
                  onPressed: _pairing ? null : _sendPin,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFe94560),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _pairing
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Onayla', style: TextStyle(fontSize: 18, color: Colors.white)),
                ),
              ),
            ],
            if (!_waitingPin && !_status.contains('Hata') && !_status.contains('kurulamadı')) ...[
              const SizedBox(height: 24),
              const CircularProgressIndicator(color: Color(0xFFe94560)),
            ],

            // Debug log paneli — her zaman görünür
            if (_logs.isNotEmpty) ...[
              const SizedBox(height: 24),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0a0a1a),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF0f3460)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('DEBUG LOG',
                        style: TextStyle(color: Color(0xFF4ade80),
                            fontSize: 10, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    ..._logs.map((l) => Text(l,
                        style: TextStyle(
                          color: l.contains('hata') || l.contains('Hata') || l.contains('başarısız')
                              ? Colors.redAccent
                              : l.contains('OK') || l.contains('tamamlandı')
                                  ? const Color(0xFF4ade80)
                                  : Colors.grey,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ))),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Pairing Session ───────────────────────────────────────────────────────────
class _AtvPairingSession {
  final String ip;
  final int pairingPort;
  final String certPem;
  final String keyPem;
  final pc.AsymmetricKeyPair<pc.RSAPublicKey, pc.RSAPrivateKey> _keyPair;

  SecureSocket? _socket;
  X509Certificate? _serverCert;

  static const _clientName = 'ATV Remote';
  static const _clientId   = 'com.mibox.remote';

  _AtvPairingSession._(this.ip, this.pairingPort, this.certPem, this.keyPem, this._keyPair);

  static Future<_AtvPairingSession> create(String ip, {int pairingPort = 6467}) async {
    // basic_utils ile doğru formatta RSA key pair + self-signed cert üret
    final keyPair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final rsaPrivate = keyPair.privateKey as pc.RSAPrivateKey;
    final rsaPublic  = keyPair.publicKey  as pc.RSAPublicKey;

    final csrPem = X509Utils.generateRsaCsrPem(
      {'CN': _clientId},
      rsaPrivate,
      rsaPublic,
    );
    final certPem = X509Utils.generateSelfSignedCertificate(
      rsaPrivate, csrPem, 3650,
    );
    final keyPem = CryptoUtils.encodeRSAPrivateKeyToPem(rsaPrivate);

    return _AtvPairingSession._(ip, pairingPort, certPem, keyPem,
        pc.AsymmetricKeyPair<pc.RSAPublicKey, pc.RSAPrivateKey>(rsaPublic, rsaPrivate));
  }

  // null = başarılı, String = hata mesajı
  Future<String?> connectWithLog(void Function(String) log) async {
    try {
      log('TLS bağlantısı kuruluyor → $ip:$pairingPort');
      final context = SecurityContext(withTrustedRoots: false);
      context.useCertificateChainBytes(utf8.encode(certPem));
      context.usePrivateKeyBytes(utf8.encode(keyPem));
      _socket = await SecureSocket.connect(ip, pairingPort,
          context: context,
          onBadCertificate: (cert) { _serverCert = cert; return true; },
          timeout: const Duration(seconds: 5));
      log('TLS OK — sunucu sertifikası alındı: ${_serverCert != null}');
      _setupDataListener();

      // 1. pairing_request
      _sendPairingRequest();
      log('→ pairing_request gönderildi');

      // 2. pairing_request_ack
      try {
        final ack = await _readMessage(timeoutMs: 3000);
        log('← pairing_request_ack: ${ack.length} byte');
      } catch (e) {
        return 'pairing_request_ack alınamadı: $e';
      }

      // 3. options
      _sendOptions();
      log('→ options gönderildi');

      // 4. options (TV'den) — bu mesajdan sonra TV PIN'i gösterir
      try {
        final opts = await _readMessage(timeoutMs: 5000);
        log('← options alındı: ${opts.length} byte — TV PIN gösteriyor olmalı');
      } catch (e) {
        return 'options alınamadı: $e';
      }

      // 5. configuration
      _sendConfiguration();
      log('→ configuration gönderildi');

      // 6. configuration_ack
      try {
        final cfgAck = await _readMessage(timeoutMs: 3000);
        log('← configuration_ack: ${cfgAck.length} byte');
      } catch (e) {
        return 'configuration_ack alınamadı: $e';
      }

      log('Handshake tamamlandı — PIN girişi bekleniyor');
      return null; // başarılı
    } catch (e) {
      return 'Bağlantı hatası: $e';
    }
  }

  // Eski connect() — geriye dönük uyumluluk
  Future<bool> connect() async {
    final err = await connectWithLog((msg) => print('[PAIR] $msg'));
    return err == null;
  }

  // Pairing akışı (ATV Remote Protocol v2):
  // 1. pairing_request (field 10)
  // 2. pairing_request_ack al
  // 3. options gönder (field 20) — encoding type + role
  // 4. options al
  // 5. configuration gönder (field 30)
  // 6. configuration_ack al
  // 7. secret gönder (field 40)
  // 8. secret_ack al

  final _receivedMessages = <List<int>>[];
  final _messageCompleter = <Completer<List<int>>>[];

  void _setupDataListener() {
    _socket!.listen(
      (data) {
        // 4 byte length prefix + payload
        var offset = 0;
        while (offset + 4 <= data.length) {
          final len = ByteData.sublistView(
              Uint8List.fromList(data.sublist(offset, offset + 4)))
              .getUint32(0, Endian.big);
          if (offset + 4 + len > data.length) break;
          final msg = data.sublist(offset + 4, offset + 4 + len);
          if (_messageCompleter.isNotEmpty) {
            _messageCompleter.removeAt(0).complete(msg);
          } else {
            _receivedMessages.add(msg);
          }
          offset += 4 + len;
        }
      },
      onError: (_) {},
      onDone: () {},
    );
  }

  Future<List<int>> _readMessage({int timeoutMs = 3000}) async {
    if (_receivedMessages.isNotEmpty) return _receivedMessages.removeAt(0);
    final c = Completer<List<int>>();
    _messageCompleter.add(c);
    return c.future.timeout(Duration(milliseconds: timeoutMs),
        onTimeout: () => throw TimeoutException('No response'));
  }

  void _sendPairingRequest() {
    // field 10 = pairing_request { field1=service_name, field2=client_name }
    final inner = _ProtoWriter()
      ..writeString(1, _clientName)
      ..writeString(2, _clientId);
    final outer = _ProtoWriter()..writeBytes(10, inner.toBytes());
    _sendMessage(outer.toBytes());
  }

  void _sendOptions() {
    // field 20 = options { input_encodings { type=3(HEX) symbol_length=6 } preferred_role=1(INPUT) }
    final encoding = _ProtoWriter()
      ..writeVarint(1, 3)   // ENCODING_TYPE_HEXADECIMAL
      ..writeVarint(2, 6);  // symbol_length
    final inner = _ProtoWriter()
      ..writeBytes(1, encoding.toBytes())  // input_encodings
      ..writeVarint(2, 1);                 // preferred_role = ROLE_TYPE_INPUT
    final outer = _ProtoWriter()..writeBytes(20, inner.toBytes());
    _sendMessage(outer.toBytes());
  }

  void _sendConfiguration() {
    // field 30 = configuration { encoding { type=3 symbol_length=6 } client_role=1 }
    final encoding = _ProtoWriter()
      ..writeVarint(1, 3)
      ..writeVarint(2, 6);
    final inner = _ProtoWriter()
      ..writeBytes(1, encoding.toBytes())
      ..writeVarint(2, 1);  // client_role = ROLE_TYPE_INPUT
    final outer = _ProtoWriter()..writeBytes(30, inner.toBytes());
    _sendMessage(outer.toBytes());
  }

  Future<bool> sendPin(String pin) async {
    if (_serverCert == null) return false;
    try {
      // options handshake
      _sendOptions();
      await _readMessage(); // options_ack

      _sendConfiguration();
      await _readMessage(); // configuration_ack

      // Secret hesapla — basic_utils ile modulus/exponent extract
      final serverCertPem = X509Utils.encodeASN1ObjectToPem(
          ASN1Object.fromBytes(_serverCert!.der), 'CERTIFICATE', 'CERTIFICATE');
      final serverModulus = CryptoUtils.rsaPublicKeyModulusToBytes(
          X509Utils.publicKeyFromX509CertificatePem(serverCertPem) as pc.RSAPublicKey);
      final serverExp = CryptoUtils.rsaPublicKeyExponentToBytes(
          X509Utils.publicKeyFromX509CertificatePem(serverCertPem) as pc.RSAPublicKey);
      final clientModulus = CryptoUtils.rsaPublicKeyModulusToBytes(_keyPair.publicKey);
      final clientExp     = CryptoUtils.rsaPublicKeyExponentToBytes(_keyPair.publicKey);
      final pinBytes      = _hexToBytes(pin.substring(4, 6));

      // SHA256(clientMod + clientExp + serverMod + serverExp + pinBytes)
      final hashInput = Uint8List(
        clientModulus.length + clientExp.length +
        serverModulus.length + serverExp.length + pinBytes.length
      );
      var offset = 0;
      hashInput.setRange(offset, offset += clientModulus.length, clientModulus);
      hashInput.setRange(offset, offset += clientExp.length, clientExp);
      hashInput.setRange(offset, offset += serverModulus.length, serverModulus);
      hashInput.setRange(offset, offset += serverExp.length, serverExp);
      hashInput.setRange(offset, offset += pinBytes.length, pinBytes);
      final secret = Uint8List.fromList(
          CryptoUtils.getHash(hashInput, algorithmName: 'SHA-256'));

      if (secret[0] != int.parse(pin.substring(0, 2), radix: 16)) {
        print('[PAIR] Secret mismatch');
        return false;
      }

      // field 40 = secret { secret=... }
      final inner = _ProtoWriter()..writeBytes(1, secret);
      final outer = _ProtoWriter()..writeBytes(40, inner.toBytes());
      _sendMessage(outer.toBytes());

      // secret_ack bekle
      await _readMessage(timeoutMs: 3000);
      return true;
    } on TimeoutException {
      print('[PAIR] Timeout waiting for response');
      return false;
    } catch (e) {
      print('[PAIR] sendPin error: $e');
      return false;
    }
  }

  void _sendMessage(Uint8List payload) {
    if (_socket == null) return;
    final lenBytes = ByteData(4);
    lenBytes.setUint32(0, payload.length, Endian.big);
    _socket!.add(lenBytes.buffer.asUint8List());
    _socket!.add(payload);
  }

  void dispose() => _socket?.destroy();

  static Uint8List _hexToBytes(String hex) {
    if (hex.length % 2 != 0) hex = '0$hex';
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}

class _ProtoWriter {
  final List<int> _buf = [];
  void writeString(int f, String v) {
    final b = utf8.encode(v);
    _writeRawVarint((f << 3) | 2); _writeRawVarint(b.length); _buf.addAll(b);
  }
  void writeBytes(int f, Uint8List v) {
    _writeRawVarint((f << 3) | 2); _writeRawVarint(v.length); _buf.addAll(v);
  }
  void _writeRawVarint(int v) {
    while (v > 0x7F) { _buf.add((v & 0x7F) | 0x80); v >>= 7; }
    _buf.add(v & 0x7F);
  }
  void writeVarint(int f, int v) {
    _writeRawVarint((f << 3) | 0);
    _writeRawVarint(v);
  }
  Uint8List toBytes() => Uint8List.fromList(_buf);
}
