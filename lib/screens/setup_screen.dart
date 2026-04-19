import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:basic_utils/basic_utils.dart';
import 'package:nsd/nsd.dart';

import '../services/mibox_service.dart';
import 'remote_screen.dart';

const _secureStorage = FlutterSecureStorage();

class DiscoveredDevice {
  final String ip;
  final bool hasCert;
  final bool hasApk;       
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

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  List<DiscoveredDevice> _devices = [];
  bool _scanning = false;
  String _scanStatus = '';
  Discovery? _discoveryV1;
  Discovery? _discoveryV2;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _stopMdnsScan();
    super.dispose();
  }

  Future<void> _stopMdnsScan() async {
    if (_discoveryV1 != null) { await stopDiscovery(_discoveryV1!); _discoveryV1 = null; }
    if (_discoveryV2 != null) { await stopDiscovery(_discoveryV2!); _discoveryV2 = null; }
  }

  Future<void> _startScan() async {
    if (_scanning) return;
    await _stopMdnsScan();

    setState(() {
      _scanning = true;
      _devices = [];
      _scanStatus = 'Ağdaki cihazlar aranıyor (mDNS)...';
    });

    final found = <DiscoveredDevice>[];
    final udpFoundIps = <String>{};

    await MiBoxService.discoverDevices(
      timeout: const Duration(seconds: 2),
      onDeviceFound: (device) {
        udpFoundIps.add(device['ip'] as String);
      },
    );

    try {
      print('mDNS Discovery Başlatılıyor...');
      _discoveryV1 = await startDiscovery('_androidtvremote._tcp');
      _discoveryV2 = await startDiscovery('_androidtvremote2._tcp');

      void handleService(Service service) async {
        print('mDNS Servis Bulundu: ${service.name} -> ${service.host}:${service.port}');
        final ip = service.host;
        final port = service.port ?? 6467;
        
        if (ip != null && !found.any((d) => d.ip == ip)) {
          final cert = await _secureStorage.read(key: 'atv_cert_$ip');
          final hasCert = cert != null && cert.isNotEmpty;
          final hasApk = udpFoundIps.contains(ip);

          final d = DiscoveredDevice(
            ip: ip, hasCert: hasCert, hasApk: hasApk,
            pairingPort: port, remotePort: 6466,
          );

          if (mounted) {
            setState(() {
              found.add(d);
              _devices = List.from(found);
            });
          }
        }
      }

      _discoveryV1!.addListener(() { 
        for (final s in _discoveryV1!.services) handleService(s); 
      });
      _discoveryV2!.addListener(() { 
        for (final s in _discoveryV2!.services) handleService(s); 
      });

      // Süreyi 5 saniyeden 8 saniyeye çıkardık
      await Future.delayed(const Duration(seconds: 8));
      await _stopMdnsScan();
      print('mDNS Tarama Tamamlandı.');

    } catch (e) {
      print('KRİTİK mDNS Hatası: $e');
    }

    if (mounted) {
      setState(() {
        _scanning = false;
        _scanStatus = found.isEmpty ? 'Cihaz bulunamadı. TV açık mı?' : '${found.length} cihaz bulundu';
      });
    }
  }

  Future<void> _connectTo(DiscoveredDevice device) async {
    final cert = await _secureStorage.read(key: 'atv_cert_${device.ip}');
    final key  = await _secureStorage.read(key: 'atv_key_${device.ip}');

    if (cert == null || key == null || cert.isEmpty || key.isEmpty) {
      if (!mounted) return;
      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => PairingScreen(ip: device.ip, pairingPort: device.pairingPort)),
      );
      if (result == true) await _launchRemote(device);
    } else {
      await _launchRemote(device);
    }
  }

  Future<void> _launchRemote(DiscoveredDevice device) async {
    MiBoxService? service;
    int remotePort = device.remotePort;

    if (device.hasApk) {
      service = MiBoxService();
      final ok = await service.connect(device.ip);
      if (!ok) service = null;
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
        service: service, ip: device.ip, remotePort: remotePort, pairingPort: device.pairingPort,
      )),
    );
  }

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
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('İptal', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFe94560)),
            child: const Text('Bağlan', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (ip == null || ip.isEmpty) return;
    final cert = await _secureStorage.read(key: 'atv_cert_$ip');
    final pairingPort = prefs.getInt('atv_pairing_port_$ip') ?? 6467;
    final remotePort  = prefs.getInt('atv_remote_port_$ip')  ?? 6466;
    bool hasApk = false;
    try {
      final s = await Socket.connect(ip, 9876, timeout: const Duration(seconds: 2));
      s.destroy(); hasApk = true;
    } catch (_) {}
    
    final device = DiscoveredDevice(ip: ip, hasCert: cert != null && cert.isNotEmpty, hasApk: hasApk, pairingPort: pairingPort, remotePort: remotePort);
    await _connectTo(device);
  }

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
                  const Text('Mi Box Remote', style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text(_scanStatus, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, fontSize: 13)),
                ],
              ),
            ),
            if (_scanning) const Padding(padding: EdgeInsets.fromLTRB(24, 0, 24, 8), child: LinearProgressIndicator(backgroundColor: Color(0xFF0f3460), color: Color(0xFFe94560), minHeight: 4)),
            Expanded(
              child: _devices.isEmpty && !_scanning
                  ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: const [Icon(Icons.devices_other, color: Colors.grey, size: 52), SizedBox(height: 12), Text('Cihaz bulunamadı', style: TextStyle(color: Colors.grey, fontSize: 16)), SizedBox(height: 4), Text('TV açık ve aynı Wi-Fi\'da mı?', style: TextStyle(color: Colors.grey, fontSize: 13))]))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _devices.length,
                      itemBuilder: (_, i) {
                        final d = _devices[i];
                        return _DeviceCard(
                          device: d,
                          onTap: () => _connectTo(d),
                          onRepair: () async {
                            await _secureStorage.delete(key: 'atv_cert_${d.ip}');
                            await _secureStorage.delete(key: 'atv_key_${d.ip}');
                            if (!mounted) return;
                            final result = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => PairingScreen(ip: d.ip, pairingPort: d.pairingPort)));
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
                      icon: _scanning ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Color(0xFFe94560), strokeWidth: 2)) : const Icon(Icons.refresh, color: Color(0xFFe94560)),
                      label: Text(_scanning ? 'Aranıyor...' : 'Yeniden Tara', style: const TextStyle(color: Color(0xFFe94560))),
                      style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFFe94560)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(vertical: 13)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _manualEntry,
                      icon: const Icon(Icons.edit, color: Colors.grey),
                      label: const Text('Manuel IP', style: TextStyle(color: Colors.grey)),
                      style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.grey), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(vertical: 13)),
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

class _DeviceCard extends StatelessWidget {
  final DiscoveredDevice device;
  final VoidCallback onTap;
  final VoidCallback onRepair;

  const _DeviceCard({required this.device, required this.onTap, required this.onRepair});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: const Color(0xFF12122a), borderRadius: BorderRadius.circular(14), border: Border.all(color: device.hasCert ? const Color(0xFF4ade80).withOpacity(0.5) : const Color(0xFF0f3460), width: 1.5)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(width: 44, height: 44, decoration: BoxDecoration(color: const Color(0xFF0f3460), borderRadius: BorderRadius.circular(10)), child: Icon(Icons.tv, color: device.hasCert ? const Color(0xFF4ade80) : const Color(0xFFe94560), size: 24)),
        title: const Text('Mi Box', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(device.ip, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 2),
            Row(
              children: [
                Text(device.hasCert ? '✓ Eşleştirildi' : 'Eşleştirilmedi', style: TextStyle(color: device.hasCert ? const Color(0xFF4ade80) : const Color(0xFFfbbf24), fontSize: 11)),
                const SizedBox(width: 8),
                Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: device.hasApk ? const Color(0xFF4ade80).withOpacity(0.15) : Colors.grey.withOpacity(0.15), borderRadius: BorderRadius.circular(4)), child: Text(device.hasApk ? 'APK ✓' : 'APK yok', style: TextStyle(color: device.hasApk ? const Color(0xFF4ade80) : Colors.grey, fontSize: 10))),
              ],
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (device.hasCert) IconButton(icon: const Icon(Icons.link_off, color: Colors.grey, size: 18), tooltip: 'Yeniden Eşleştir', onPressed: onRepair),
            ElevatedButton(onPressed: onTap, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFe94560), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8)), child: Text(device.hasCert ? 'Bağlan' : 'Eşleştir', style: const TextStyle(color: Colors.white, fontSize: 13))),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

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

  Future<void> _startPairing() async {
    _logs.clear();
    try {
      _log('Sertifika oluşturuluyor...');
      setState(() => _status = 'Sertifika oluşturuluyor...');
      final portsToTry = [widget.pairingPort, ...[6467, 6468, 7676].where((p) => p != widget.pairingPort)];
      final sharedSession = await _AtvPairingSession.create(widget.ip);

      int? workingPort;
      for (final port in portsToTry) {
        _log('Port $port deneniyor...');
        setState(() => _status = 'Bağlanılıyor... (port $port)');
        final sessionForPort = sharedSession.withPort(port);
        final error = await sessionForPort.connectWithLog(_log);
        if (error == null) {
          _session = sessionForPort;
          workingPort = port;
          _log('Port $port OK — PIN bekleniyor');
          break;
        } else {
          _log('Port $port hata: $error');
          sessionForPort.close();
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
      _session!._log = (msg) { print('[PAIR] $msg'); if (mounted) setState(() => _logs.add('[PIN] $msg')); };
      final ok = await _session!.sendPin(pin);
      if (ok) {
        await _secureStorage.write(key: 'atv_cert_${widget.ip}', value: _session!.certPem);
        await _secureStorage.write(key: 'atv_key_${widget.ip}',  value: _session!.keyPem);
        _log('Sertifikalar Güvenli Depolamaya kaydedildi.');
        await Future.delayed(const Duration(seconds: 3));
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
  void dispose() { _session?.close(); _pinController.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(backgroundColor: const Color(0xFF12122a), title: Text('TV Eşleştirme — ${widget.ip}', style: const TextStyle(color: Colors.white, fontSize: 15)), iconTheme: const IconThemeData(color: Colors.white)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.link, color: Color(0xFFe94560), size: 64),
            const SizedBox(height: 24),
            Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16)),
            if (_waitingPin) ...[
              const SizedBox(height: 32),
              TextField(
                controller: _pinController, autofocus: true, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 32, letterSpacing: 8, fontWeight: FontWeight.bold), maxLength: 6, textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(hintText: 'XXXXXX', hintStyle: const TextStyle(color: Colors.grey, fontSize: 32), filled: true, fillColor: const Color(0xFF0f3460), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none), focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFe94560))), counterText: ''),
                onSubmitted: (_) => _sendPin(),
              ),
              const SizedBox(height: 24),
              SizedBox(width: double.infinity, height: 52, child: ElevatedButton(onPressed: _pairing ? null : _sendPin, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFe94560), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), child: _pairing ? const CircularProgressIndicator(color: Colors.white) : const Text('Onayla', style: TextStyle(fontSize: 18, color: Colors.white)))),
            ],
            if (!_waitingPin && !_status.contains('Hata') && !_status.contains('kurulamadı')) ...[const SizedBox(height: 24), const CircularProgressIndicator(color: Color(0xFFe94560))],
            if (_logs.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity, height: 200, decoration: BoxDecoration(color: const Color(0xFF0a0a1a), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF0f3460))),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(padding: const EdgeInsets.fromLTRB(8, 6, 8, 2), child: Row(children: [const Text('DEBUG LOG', style: TextStyle(color: Color(0xFF4ade80), fontSize: 10, fontWeight: FontWeight.bold)), const Spacer(), GestureDetector(onTap: () => setState(() => _logs.clear()), child: const Text('Temizle', style: TextStyle(color: Colors.grey, fontSize: 9)))])),
                    Expanded(child: ListView.builder(reverse: true, padding: const EdgeInsets.fromLTRB(8, 0, 8, 8), itemCount: _logs.length, itemBuilder: (_, i) => Text(_logs[i], style: TextStyle(color: _logs[i].contains('mismatch') || _logs[i].contains('hata') || _logs[i].contains('Hata') ? Colors.redAccent : _logs[i].contains('match=true') || _logs[i].contains('OK') || _logs[i].contains('BAŞARILI') ? const Color(0xFF4ade80) : Colors.grey, fontSize: 10, fontFamily: 'monospace')))),
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

  _AtvPairingSession withPort(int port) => _AtvPairingSession._(ip, port, certPem, keyPem, _keyPair);

  static Future<_AtvPairingSession> create(String ip, {int pairingPort = 6467}) async {
    final keyPair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final rsaPrivate = keyPair.privateKey as pc.RSAPrivateKey;
    final rsaPublic  = keyPair.publicKey  as pc.RSAPublicKey;
    final csrPem = X509Utils.generateRsaCsrPem({'CN': _clientId}, rsaPrivate, rsaPublic);
    final notBefore = DateTime.now().subtract(const Duration(days: 1));
    final certPem = X509Utils.generateSelfSignedCertificate(rsaPrivate, csrPem, 3650, notBefore: notBefore);
    final keyPem = CryptoUtils.encodeRSAPrivateKeyToPem(rsaPrivate);
    return _AtvPairingSession._(ip, pairingPort, certPem, keyPem, pc.AsymmetricKeyPair<pc.RSAPublicKey, pc.RSAPrivateKey>(rsaPublic, rsaPrivate));
  }

  Future<String?> connectWithLog(void Function(String) log) async {
    _log = log;
    try {
      final context = SecurityContext(withTrustedRoots: false);
      context.useCertificateChainBytes(utf8.encode(certPem)); 
      context.usePrivateKeyBytes(utf8.encode(keyPem));          
      _socket = await SecureSocket.connect(ip, pairingPort, context: context, onBadCertificate: (cert) { _serverCert = cert; return true; }, timeout: const Duration(seconds: 5));
      _setupDataListener();

      _sendMessage(_buildPairingRequestBytes());
      try { await _readMessage(timeoutMs: 3000); } catch (e) { return 'pairing_request_ack alınamadı: $e'; }
      _sendOptions();
      try { await _readMessage(timeoutMs: 5000); } catch (e) { return 'options alınamadı: $e'; }
      _sendConfiguration();
      try { await _readMessage(timeoutMs: 3000); } catch (e) { return 'configuration_ack alınamadı: $e'; }
      
      log('Handshake tamamlandı — PIN girişi bekleniyor');
      return null; 
    } catch (e) {
      return 'Bağlantı hatası: $e';
    }
  }

  final _receivedMessages = <List<int>>[];
  final _messageCompleter = <Completer<List<int>>>[];
  void Function(String)? _log;
  final _recvBuffer = <int>[];
  Timer? _flushTimer;

  void _setupDataListener() {
    _socket!.listen(
      (data) { _recvBuffer.addAll(data); _flushTimer?.cancel(); _flushTimer = Timer(const Duration(milliseconds: 10), _processBuffer); },
      onError: (e) => _log?.call('← TV socket error: $e'), onDone: ()  => _log?.call('← TV socket closed'),
    );
  }

  void _processBuffer() {
    while (_recvBuffer.isNotEmpty) {
      final expectedLen = _recvBuffer[0];
      if (_recvBuffer.length < 1 + expectedLen) break; 
      final msg = _recvBuffer.sublist(1, 1 + expectedLen);
      _recvBuffer.removeRange(0, 1 + expectedLen);
      if (_messageCompleter.isNotEmpty) _messageCompleter.removeAt(0).complete(msg); else _receivedMessages.add(msg);
    }
  }

  Future<List<int>> _readMessage({int timeoutMs = 3000}) async {
    if (_receivedMessages.isNotEmpty) return _receivedMessages.removeAt(0);
    final c = Completer<List<int>>();
    _messageCompleter.add(c);
    return c.future.timeout(Duration(milliseconds: timeoutMs), onTimeout: () => throw TimeoutException('No response'));
  }

  Uint8List _buildPairingRequestBytes() {
    final serviceBytes = utf8.encode(_clientName);
    final clientBytes  = utf8.encode(_clientId);
    final innerLen = 2 + serviceBytes.length + 2 + clientBytes.length;
    return Uint8List.fromList([8, 2, 16, 200, 1, 82, innerLen, 10, serviceBytes.length, ...serviceBytes, 18, clientBytes.length, ...clientBytes]);
  }

  void _sendOptions() => _sendMessage(Uint8List.fromList([8, 2, 16, 200, 1, 162, 1, 8, 10, 4, 8, 3, 16, 6, 24, 1]));
  void _sendConfiguration() => _sendMessage(Uint8List.fromList([8, 2, 16, 200, 1, 242, 1, 8, 10, 4, 8, 3, 16, 6, 16, 1]));

  Future<bool> sendPin(String pin) async {
    if (_serverCert == null) return false;
    try {
      final serverPem = _derToCertPem(_serverCert!.der);
      final serverParsedCert = X509Utils.x509CertificateFromPem(serverPem);

      final pubKeyHex = serverParsedCert.publicKeyData.bytes;
      if (pubKeyHex == null) {
        _log?.call('HATA: Sertifikadan public key okunamadı.');
        return false;
      }

      final cleanHex = pubKeyHex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
      final pubKeyBytes = _hexToBytes(cleanHex);

      final b64 = base64.encode(pubKeyBytes);
      final sb = StringBuffer('-----BEGIN PUBLIC KEY-----\n');
      for (var i = 0; i < b64.length; i += 64) sb.writeln(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
      sb.write('-----END PUBLIC KEY-----');
      
      final serverPubKey = CryptoUtils.rsaPublicKeyFromPem(sb.toString());

      final serverModulus = _getCleanModulus(serverPubKey.modulus!);
      final serverExp     = _getCleanModulus(serverPubKey.exponent!);
      final clientModulus = _getCleanModulus(_keyPair.publicKey.modulus!);
      final clientExp     = _getCleanModulus(_keyPair.publicKey.exponent!);

      final checkByte   = int.parse(pin.substring(0, 2), radix: 16);
      final pinHashPart = _hexToBytes(pin.substring(2)); 

      _log?.call('sendPin: checkByte=${checkByte.toRadixString(16)}');
      
      final hashInput = Uint8List.fromList([...clientModulus, ...clientExp, ...serverModulus, ...serverExp, ...pinHashPart]);
      final secret = pc.SHA256Digest().process(hashInput);

      if (secret[0] != checkByte) {
        _log?.call('Secret mismatch! Hash hesaplaması başarısız.');
        return false;
      }

      _sendMessage(Uint8List.fromList([8, 2, 16, 200, 1, 98, 34, 10, 32, ...secret]));
      await _readMessage(timeoutMs: 3000);
      _log?.call('← secret_ack alındı: Eşleştirme BAŞARILI!');
      return true;
    } on TimeoutException {
      print('[PAIR] Timeout waiting for response');
      return false;
    } catch (e) {
      print('[PAIR] sendPin error: $e');
      return false;
    }
  }

  void _sendMessage(Uint8List payload) { if (_socket != null) _socket!.add(Uint8List.fromList([payload.length, ...payload])); }

  static String _derToCertPem(Uint8List der) {
    final b64 = base64.encode(der);
    final sb = StringBuffer('-----BEGIN CERTIFICATE-----\n');
    for (var i = 0; i < b64.length; i += 64) sb.writeln(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
    sb.write('-----END CERTIFICATE-----');
    return sb.toString();
  }

  static Uint8List _getCleanModulus(BigInt n) {
    var hex = n.toRadixString(16);
    if (hex.length % 2 != 0) hex = '0$hex';
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (bytes.isNotEmpty && bytes[0] == 0x00) return bytes.sublist(1);
    return bytes;
  }

  void close() => _socket?.destroy();

  static Uint8List _hexToBytes(String hex) {
    if (hex.length % 2 != 0) hex = '0$hex';
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    return bytes;
  }
}