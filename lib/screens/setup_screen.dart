import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:asn1lib/asn1lib.dart' as asn1;
import '../services/mibox_service.dart';
import 'remote_screen.dart';

// ── Bulunan cihaz modeli ────────────────────────────────────────────────────
class DiscoveredDevice {
  final String ip;
  final bool hasCert;
  const DiscoveredDevice({required this.ip, required this.hasCert});
}

// ── Setup Screen ─────────────────────────────────────────────────────────────
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

  Future<String?> _getSubnet() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') || ip.startsWith('10.')) {
            final parts = ip.split('.');
            return '${parts[0]}.${parts[1]}.${parts[2]}';
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<bool> _checkAtv(String ip) async {
    for (final port in [6466, 6467]) {
      try {
        final sock = await Socket.connect(ip, port,
            timeout: const Duration(milliseconds: 400));
        sock.destroy();
        return true;
      } catch (_) {}
    }
    return false;
  }

  Future<void> _startScan() async {
    setState(() {
      _scanning = true;
      _devices = [];
      _scanStatus = 'Ağ adresi alınıyor...';
      _scanned = 0;
      _total = 0;
    });

    final subnet = await _getSubnet();
    if (subnet == null) {
      setState(() {
        _scanning = false;
        _scanStatus = 'Wi-Fi ağı bulunamadı.\nWi-Fi\'a bağlı olduğunuzdan emin olun.';
      });
      return;
    }

    setState(() {
      _scanStatus = 'Taranıyor: $subnet.0/24';
      _total = 254;
    });

    final prefs = await SharedPreferences.getInstance();
    final found = <DiscoveredDevice>[];
    const batchSize = 20;

    for (var start = 1; start <= 254; start += batchSize) {
      if (!mounted) return;
      final end = min(start + batchSize - 1, 254);
      final futures = <Future<void>>[];

      for (var i = start; i <= end; i++) {
        final ip = '$subnet.$i';
        futures.add(() async {
          final hasAtv = await _checkAtv(ip);
          if (hasAtv) {
            final hasCert = (prefs.getString('mibox_cert_$ip') ?? '').isNotEmpty;
            found.add(DiscoveredDevice(ip: ip, hasCert: hasCert));
            if (mounted) setState(() => _devices = List.from(found));
          }
        }());
      }

      await Future.wait(futures);
      if (mounted) setState(() => _scanned = end);
    }

    if (mounted) {
      setState(() {
        _scanning = false;
        _scanStatus = found.isEmpty
            ? 'Cihaz bulunamadı. TV açık ve aynı ağda mı?'
            : '${found.length} cihaz bulundu';
      });
    }
  }

  Future<void> _connectTo(DiscoveredDevice device) async {
    final prefs = await SharedPreferences.getInstance();
    final cert = prefs.getString('mibox_cert_${device.ip}') ?? '';
    final key = prefs.getString('mibox_key_${device.ip}') ?? '';

    if (cert.isEmpty || key.isEmpty) {
      if (!mounted) return;
      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => PairingScreen(ip: device.ip)),
      );
      if (result == true) await _launchRemote(device.ip);
    } else {
      await _launchRemote(device.ip);
    }
  }

  Future<void> _launchRemote(String ip) async {
    final service = MiBoxService();
    final ok = await service.connect(ip);
    if (!mounted) return;
    if (ok) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('mibox_ip', ip);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => RemoteScreen(service: service, ip: ip)),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$ip — AirCursor APK çalışmıyor!'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _manualEntry() async {
    final ctrl = TextEditingController(text: '192.168.1.');
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
            hintText: '192.168.1.xxx',
            hintStyle: const TextStyle(color: Colors.grey),
            filled: true,
            fillColor: const Color(0xFF0f3460),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('İptal', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFe94560)),
            child: const Text('Bağlan', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (ip == null || ip.isEmpty) return;
    final cert = prefs.getString('mibox_cert_$ip') ?? '';
    final device = DiscoveredDevice(ip: ip, hasCert: cert.isNotEmpty);
    await _connectTo(device);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 16),
              child: Column(
                children: [
                  const Icon(Icons.tv, color: Color(0xFFe94560), size: 56),
                  const SizedBox(height: 10),
                  const Text('Mi Box Remote',
                      style: TextStyle(
                          color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text(_scanStatus,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey, fontSize: 13)),
                ],
              ),
            ),

            // Progress
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

            // Liste
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
                            await prefs.remove('mibox_cert_${d.ip}');
                            await prefs.remove('mibox_key_${d.ip}');
                            if (!mounted) return;
                            final result = await Navigator.push<bool>(
                              context,
                              MaterialPageRoute(builder: (_) => PairingScreen(ip: d.ip)),
                            );
                            if (result == true) await _launchRemote(d.ip);
                          },
                        );
                      },
                    ),
            ),

            // Alt butonlar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _scanning ? null : _startScan,
                      icon: _scanning
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(
                                  color: Color(0xFFe94560), strokeWidth: 2))
                          : const Icon(Icons.refresh, color: Color(0xFFe94560)),
                      label: Text(_scanning ? 'Taranıyor...' : 'Yeniden Tara',
                          style: const TextStyle(color: Color(0xFFe94560))),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFFe94560)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _manualEntry,
                      icon: const Icon(Icons.edit, color: Colors.grey),
                      label: const Text('Manuel IP',
                          style: TextStyle(color: Colors.grey)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.grey),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
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

  const _DeviceCard({
    required this.device,
    required this.onTap,
    required this.onRepair,
  });

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
          decoration: BoxDecoration(
            color: const Color(0xFF0f3460),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.tv,
            color: device.hasCert ? const Color(0xFF4ade80) : const Color(0xFFe94560),
            size: 24,
          ),
        ),
        title: const Text('Mi Box',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(device.ip, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 2),
            Text(
              device.hasCert ? '✓ Eşleştirildi' : 'Eşleştirilmedi',
              style: TextStyle(
                color: device.hasCert ? const Color(0xFF4ade80) : const Color(0xFFfbbf24),
                fontSize: 11,
              ),
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
              child: Text(
                device.hasCert ? 'Bağlan' : 'Eşleştir',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
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
  const PairingScreen({super.key, required this.ip});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _pinController = TextEditingController();
  String _status = 'Sertifika oluşturuluyor...';
  bool _waitingPin = false;
  bool _pairing = false;
  _AtvPairingSession? _session;

  @override
  void initState() {
    super.initState();
    _startPairing();
  }

  Future<void> _startPairing() async {
    try {
      setState(() => _status = 'Sertifika oluşturuluyor...');
      _session = await _AtvPairingSession.create(widget.ip);
      setState(() => _status = 'TV\'ye bağlanılıyor...');
      final ok = await _session!.connect();
      if (ok) {
        setState(() {
          _status = 'TV ekranındaki 6 haneli kodu girin:';
          _waitingPin = true;
        });
      } else {
        setState(() => _status = 'Bağlantı hatası! TV açık mı?\n(port 6467)');
      }
    } catch (e) {
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
        await prefs.setString('mibox_cert_${widget.ip}', _session!.certPem);
        await prefs.setString('mibox_key_${widget.ip}', _session!.keyPem);
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
            Text(_status,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16)),
            if (_waitingPin) ...[
              const SizedBox(height: 32),
              TextField(
                controller: _pinController,
                autofocus: true,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white, fontSize: 32, letterSpacing: 8, fontWeight: FontWeight.bold),
                maxLength: 6,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  hintText: 'XXXXXX',
                  hintStyle: const TextStyle(color: Colors.grey, fontSize: 32),
                  filled: true,
                  fillColor: const Color(0xFF0f3460),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
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
            if (!_waitingPin && !_status.contains('Hata')) ...[
              const SizedBox(height: 24),
              const CircularProgressIndicator(color: Color(0xFFe94560)),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Pairing Session ───────────────────────────────────────────────────────────
class _AtvPairingSession {
  static const int _pairingPort = 6467;

  final String ip;
  final String certPem;
  final String keyPem;
  final pc.AsymmetricKeyPair<pc.RSAPublicKey, pc.RSAPrivateKey> _keyPair;

  SecureSocket? _socket;
  X509Certificate? _serverCert;

  _AtvPairingSession._(this.ip, this.certPem, this.keyPem, this._keyPair);

  static Future<_AtvPairingSession> create(String ip) async {
    final keyPair = _generateRSAKeyPair();
    final certPem = _generateSelfSignedCert(keyPair);
    final keyPem = _encodePrivateKeyToPem(keyPair.privateKey);
    return _AtvPairingSession._(ip, certPem, keyPem, keyPair);
  }

  Future<bool> connect() async {
    try {
      final context = SecurityContext(withTrustedRoots: false);
      context.useCertificateChainBytes(utf8.encode(certPem));
      context.usePrivateKeyBytes(utf8.encode(keyPem));
      _socket = await SecureSocket.connect(
        ip, _pairingPort,
        context: context,
        onBadCertificate: (cert) { _serverCert = cert; return true; },
        timeout: const Duration(seconds: 5),
      );
      _socket!.listen((_) {}, onError: (_) {}, onDone: () {});
      _sendPairingRequest();
      await Future.delayed(const Duration(milliseconds: 500));
      return true;
    } catch (e) {
      print('[PAIR] connect error: $e');
      return false;
    }
  }

  void _sendPairingRequest() {
    final inner = _ProtoWriter()
      ..writeString(1, 'MiBoxRemote')
      ..writeString(2, 'MiBoxRemote');
    final outer = _ProtoWriter()..writeBytes(10, inner.toBytes());
    _sendMessage(outer.toBytes());
  }

  Future<bool> sendPin(String pin) async {
    if (_serverCert == null) return false;
    try {
      final serverDer = _serverCert!.der;
      final serverModulus = _extractModulusFromDer(serverDer);
      final serverExponent = _extractExponentFromDer(serverDer);
      final clientModulus = _bigIntToBytes(_keyPair.publicKey.modulus!);
      final clientExponent = _bigIntToBytes(_keyPair.publicKey.exponent!);
      final pinBytes = _hexToBytes(pin.substring(4, 6));

      final sha256 = pc.SHA256Digest();
      sha256.update(clientModulus, 0, clientModulus.length);
      sha256.update(clientExponent, 0, clientExponent.length);
      sha256.update(serverModulus, 0, serverModulus.length);
      sha256.update(serverExponent, 0, serverExponent.length);
      sha256.update(pinBytes, 0, pinBytes.length);
      final secret = Uint8List(32);
      sha256.doFinal(secret, 0);

      final pinFirstByte = int.parse(pin.substring(0, 2), radix: 16);
      if (secret[0] != pinFirstByte) return false;

      final inner = _ProtoWriter()..writeBytes(1, secret);
      final outer = _ProtoWriter()..writeBytes(11, inner.toBytes());
      _sendMessage(outer.toBytes());
      await Future.delayed(const Duration(milliseconds: 1000));
      return true;
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

  static pc.AsymmetricKeyPair<pc.RSAPublicKey, pc.RSAPrivateKey> _generateRSAKeyPair() {
    final secureRandom = pc.FortunaRandom();
    final seedSource = Random.secure();
    secureRandom.seed(pc.KeyParameter(
        Uint8List.fromList(List.generate(32, (_) => seedSource.nextInt(256)))));
    final keyGen = pc.RSAKeyGenerator()
      ..init(pc.ParametersWithRandom(
          pc.RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64), secureRandom));
    final pair = keyGen.generateKeyPair();
    return pc.AsymmetricKeyPair<pc.RSAPublicKey, pc.RSAPrivateKey>(
        pair.publicKey as pc.RSAPublicKey, pair.privateKey as pc.RSAPrivateKey);
  }

  static String _generateSelfSignedCert(
      pc.AsymmetricKeyPair<pc.RSAPublicKey, pc.RSAPrivateKey> keyPair) {
    final tbsCert = asn1.ASN1Sequence();
    final versionTag = asn1.ASN1Sequence();
    versionTag.add(asn1.ASN1Integer(BigInt.from(2)));
    tbsCert.add(asn1.ASN1Object.fromBytes(
        Uint8List.fromList([0xa0, ...versionTag.encodedBytes])));
    tbsCert.add(asn1.ASN1Integer(BigInt.from(1)));
    final sigAlg = asn1.ASN1Sequence();
    sigAlg.add(asn1.ASN1ObjectIdentifier.fromBytes(Uint8List.fromList(
        [0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b])));
    sigAlg.add(asn1.ASN1Null());
    tbsCert.add(sigAlg);
    tbsCert.add(_buildName('MiBoxRemote'));
    final now = DateTime.now().toUtc();
    final validity = asn1.ASN1Sequence();
    validity.add(asn1.ASN1UtcTime(now));
    validity.add(asn1.ASN1UtcTime(now.add(const Duration(days: 3650))));
    tbsCert.add(validity);
    tbsCert.add(_buildName('MiBoxRemote'));
    tbsCert.add(_buildPublicKeyInfo(keyPair.publicKey));

    final signer = pc.RSASigner(pc.SHA256Digest(), '0609608648016503040201')
      ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(keyPair.privateKey));
    final sig = signer.generateSignature(tbsCert.encodedBytes) as pc.RSASignature;

    final cert = asn1.ASN1Sequence();
    cert.add(tbsCert);
    cert.add(sigAlg);
    cert.add(asn1.ASN1BitString(Uint8List.fromList([0, ...sig.bytes])));

    final b64 = base64.encode(cert.encodedBytes);
    final lines = ['-----BEGIN CERTIFICATE-----'];
    for (var i = 0; i < b64.length; i += 64) {
      lines.add(b64.substring(i, min(i + 64, b64.length)));
    }
    lines.add('-----END CERTIFICATE-----');
    return lines.join('\n');
  }

  static asn1.ASN1Sequence _buildName(String cn) {
    final rdnSeq = asn1.ASN1Sequence();
    final rdn = asn1.ASN1Set();
    final atv = asn1.ASN1Sequence();
    atv.add(asn1.ASN1ObjectIdentifier.fromBytes(
        Uint8List.fromList([0x06,0x03,0x55,0x04,0x03])));
    atv.add(asn1.ASN1UTF8String(utf8String: cn));
    rdn.add(atv);
    rdnSeq.add(rdn);
    return rdnSeq;
  }

  static asn1.ASN1Sequence _buildPublicKeyInfo(pc.RSAPublicKey publicKey) {
    final spki = asn1.ASN1Sequence();
    final alg = asn1.ASN1Sequence();
    alg.add(asn1.ASN1ObjectIdentifier.fromBytes(Uint8List.fromList(
        [0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01])));
    alg.add(asn1.ASN1Null());
    spki.add(alg);
    final pubKeySeq = asn1.ASN1Sequence();
    pubKeySeq.add(asn1.ASN1Integer(publicKey.modulus!));
    pubKeySeq.add(asn1.ASN1Integer(publicKey.exponent!));
    spki.add(asn1.ASN1BitString(Uint8List.fromList([0, ...pubKeySeq.encodedBytes])));
    return spki;
  }

  static String _encodePrivateKeyToPem(pc.RSAPrivateKey pk) {
    final seq = asn1.ASN1Sequence();
    seq.add(asn1.ASN1Integer(BigInt.zero));
    seq.add(asn1.ASN1Integer(pk.modulus!));
    seq.add(asn1.ASN1Integer(pk.exponent!));
    seq.add(asn1.ASN1Integer(pk.privateExponent!));
    seq.add(asn1.ASN1Integer(pk.p!));
    seq.add(asn1.ASN1Integer(pk.q!));
    seq.add(asn1.ASN1Integer(pk.privateExponent! % (pk.p! - BigInt.one)));
    seq.add(asn1.ASN1Integer(pk.privateExponent! % (pk.q! - BigInt.one)));
    seq.add(asn1.ASN1Integer(pk.q!.modInverse(pk.p!)));
    final b64 = base64.encode(seq.encodedBytes);
    final lines = ['-----BEGIN RSA PRIVATE KEY-----'];
    for (var i = 0; i < b64.length; i += 64) {
      lines.add(b64.substring(i, min(i + 64, b64.length)));
    }
    lines.add('-----END RSA PRIVATE KEY-----');
    return lines.join('\n');
  }

  static Uint8List _extractModulusFromDer(Uint8List der) {
    try {
      final seq = asn1.ASN1Parser(der).nextObject() as asn1.ASN1Sequence;
      final tbs = seq.elements![0] as asn1.ASN1Sequence;
      final spki = tbs.elements![6] as asn1.ASN1Sequence;
      final bitStr = spki.elements![1] as asn1.ASN1BitString;
      final pubKeySeq = asn1.ASN1Parser(bitStr.contentBytes().sublist(1))
          .nextObject() as asn1.ASN1Sequence;
      return _bigIntToBytes((pubKeySeq.elements![0] as asn1.ASN1Integer).integer!);
    } catch (_) { return Uint8List(0); }
  }

  static Uint8List _extractExponentFromDer(Uint8List der) {
    try {
      final seq = asn1.ASN1Parser(der).nextObject() as asn1.ASN1Sequence;
      final tbs = seq.elements![0] as asn1.ASN1Sequence;
      final spki = tbs.elements![6] as asn1.ASN1Sequence;
      final bitStr = spki.elements![1] as asn1.ASN1BitString;
      final pubKeySeq = asn1.ASN1Parser(bitStr.contentBytes().sublist(1))
          .nextObject() as asn1.ASN1Sequence;
      return _bigIntToBytes((pubKeySeq.elements![1] as asn1.ASN1Integer).integer!);
    } catch (_) { return Uint8List(0); }
  }

  static Uint8List _bigIntToBytes(BigInt n) {
    var hex = n.toRadixString(16);
    if (hex.length % 2 != 0) hex = '0$hex';
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  static Uint8List _hexToBytes(String hex) {
    if (hex.length % 2 != 0) hex = '0$hex';
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}

// ── Proto Writer ──────────────────────────────────────────────────────────────
class _ProtoWriter {
  final List<int> _buf = [];

  void writeString(int fieldNumber, String value) {
    final bytes = utf8.encode(value);
    _writeRawVarint((fieldNumber << 3) | 2);
    _writeRawVarint(bytes.length);
    _buf.addAll(bytes);
  }

  void writeBytes(int fieldNumber, Uint8List value) {
    _writeRawVarint((fieldNumber << 3) | 2);
    _writeRawVarint(value.length);
    _buf.addAll(value);
  }

  void _writeRawVarint(int value) {
    while (value > 0x7F) {
      _buf.add((value & 0x7F) | 0x80);
      value >>= 7;
    }
    _buf.add(value & 0x7F);
  }

  Uint8List toBytes() => Uint8List.fromList(_buf);
}
