import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pointycastle/export.dart';
import 'package:asn1lib/asn1lib.dart';
import '../services/mibox_service.dart';
import 'remote_screen.dart';

// ── Setup Screen ────────────────────────────────────────────────────────────
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
    if (ip != null) setState(() => _ipController.text = ip);
  }

  Future<void> _connect() async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;

    setState(() { _connecting = true; _status = 'Kontrol ediliyor...'; });

    final prefs = await SharedPreferences.getInstance();
    final cert = prefs.getString('mibox_cert') ?? '';
    final key = prefs.getString('mibox_key') ?? '';

    if (cert.isEmpty || key.isEmpty) {
      setState(() { _connecting = false; _status = ''; });
      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => PairingScreen(ip: ip)),
      );
      if (result == true) await _doConnect(ip);
    } else {
      await _doConnect(ip);
    }
  }

  Future<void> _doConnect(String ip) async {
    setState(() { _connecting = true; _status = 'Baglaniliyor...'; });
    final service = MiBoxService();
    final ok = await service.connect(ip);
    if (ok) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('mibox_ip', ip);
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => RemoteScreen(service: service, ip: ip)),
        );
      }
    } else {
      setState(() {
        _connecting = false;
        _status = 'Baglanamadi! IP dogru mu?\nAirCursor APK calisiyor mu?';
      });
    }
  }

  @override
  void dispose() { _ipController.dispose(); super.dispose(); }

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
              const Text('Mi Box Remote', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Mi Box IP adresini girin', style: TextStyle(color: Colors.grey, fontSize: 14)),
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
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  prefixIcon: const Icon(Icons.wifi, color: Color(0xFFe94560)),
                ),
              ),
              const SizedBox(height: 8),
              const Text('Mi Box Settings > About > Network', style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity, height: 52,
                child: ElevatedButton(
                  onPressed: _connecting ? null : _connect,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFe94560),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _connecting
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Baglan', style: TextStyle(fontSize: 18, color: Colors.white)),
                ),
              ),
              if (_status.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(_status, textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _status.contains('Baglanamadi') ? Colors.redAccent : Colors.greenAccent,
                      fontSize: 14,
                    )),
              ],
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () async {
                  final ip = _ipController.text.trim();
                  if (ip.isEmpty) return;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.remove('mibox_cert');
                  await prefs.remove('mibox_key');
                  if (mounted) {
                    final result = await Navigator.push<bool>(
                      context, MaterialPageRoute(builder: (_) => PairingScreen(ip: ip)));
                    if (result == true) await _doConnect(ip);
                  }
                },
                icon: const Icon(Icons.link, color: Colors.grey, size: 16),
                label: const Text('TV ile Yeniden Eslestir', style: TextStyle(color: Colors.grey, fontSize: 12)),
              ),
              const SizedBox(height: 16),
              const Text('Mi Box\'ta AirCursor APK calisiyor olmali',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Pairing Screen ──────────────────────────────────────────────────────────
class PairingScreen extends StatefulWidget {
  final String ip;
  const PairingScreen({super.key, required this.ip});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _pinController = TextEditingController();
  String _status = 'Sertifika olusturuluyor...';
  bool _waitingPin = false;
  bool _pairing = false;
  _AtvPairingSession? _session;

  @override
  void initState() { super.initState(); _startPairing(); }

  Future<void> _startPairing() async {
    try {
      setState(() => _status = 'Sertifika olusturuluyor...');
      _session = await _AtvPairingSession.create(widget.ip);
      setState(() => _status = 'TV\'ye baglaniliyor...');
      final ok = await _session!.connect();
      if (ok) {
        setState(() { _status = 'TV ekranindaki 6 haneli kodu girin:'; _waitingPin = true; });
      } else {
        setState(() => _status = 'Baglanti hatasi! TV acik mi?');
      }
    } catch (e) {
      setState(() => _status = 'Hata: $e');
    }
  }

  Future<void> _sendPin() async {
    final pin = _pinController.text.trim().toUpperCase();
    if (pin.length < 6) return;
    setState(() { _pairing = true; _status = 'Dogrulanıyor...'; });
    try {
      final ok = await _session!.sendPin(pin);
      if (ok) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('mibox_cert', _session!.certPem);
        await prefs.setString('mibox_key', _session!.keyPem);
        if (mounted) Navigator.pop(context, true);
      } else {
        setState(() { _pairing = false; _status = 'Yanlis kod! Tekrar deneyin:'; });
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
        title: const Text('TV Eslestirme', style: TextStyle(color: Colors.white)),
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
                style: const TextStyle(color: Colors.white, fontSize: 32, letterSpacing: 8, fontWeight: FontWeight.bold),
                maxLength: 6,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  hintText: 'XXXXXX',
                  hintStyle: const TextStyle(color: Colors.grey, fontSize: 32),
                  filled: true,
                  fillColor: const Color(0xFF0f3460),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFe94560))),
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

// ── Pairing Session ─────────────────────────────────────────────────────────
class _AtvPairingSession {
  static const int PAIRING_PORT = 6467;

  final String ip;
  final String certPem;
  final String keyPem;
  final AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _keyPair;

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

      _socket = await SecureSocket.connect(ip, PAIRING_PORT,
          context: context,
          onBadCertificate: (cert) { _serverCert = cert; return true; },
          timeout: const Duration(seconds: 5));

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
    final inner = _ProtoWriter();
    inner.writeString(1, 'MiBoxRemote');
    inner.writeString(2, 'MiBoxRemote');
    final outer = _ProtoWriter();
    outer.writeBytes(10, inner.toBytes());
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

      final sha256 = SHA256Digest();
      sha256.update(clientModulus, 0, clientModulus.length);
      sha256.update(clientExponent, 0, clientExponent.length);
      sha256.update(serverModulus, 0, serverModulus.length);
      sha256.update(serverExponent, 0, serverExponent.length);
      sha256.update(pinBytes, 0, pinBytes.length);
      final secret = Uint8List(32);
      sha256.doFinal(secret, 0);

      final pinFirstByte = int.parse(pin.substring(0, 2), radix: 16);
      if (secret[0] != pinFirstByte) {
        print('[PAIR] Secret mismatch');
        return false;
      }

      final inner = _ProtoWriter();
      inner.writeBytes(1, secret);
      final outer = _ProtoWriter();
      outer.writeBytes(11, inner.toBytes());
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

  void dispose() { _socket?.destroy(); }

  static AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _generateRSAKeyPair() {
    final secureRandom = FortunaRandom();
    final seedSource = Random.secure();
    secureRandom.seed(KeyParameter(
        Uint8List.fromList(List.generate(32, (_) => seedSource.nextInt(256)))));
    final keyGen = RSAKeyGenerator()
      ..init(ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64), secureRandom));
    final pair = keyGen.generateKeyPair();
    return AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey>(
        pair.publicKey as RSAPublicKey, pair.privateKey as RSAPrivateKey);
  }

  static String _generateSelfSignedCert(
      AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> keyPair) {
    final tbsCert = ASN1Sequence();
    final versionTag = ASN1Sequence();
    versionTag.add(ASN1Integer(BigInt.from(2)));
    tbsCert.add(ASN1Object.fromBytes(Uint8List.fromList([0xa0, ...versionTag.encodedBytes])));
    tbsCert.add(ASN1Integer(BigInt.from(1)));
    final sigAlg = ASN1Sequence();
    sigAlg.add(ASN1ObjectIdentifier.fromBytes(Uint8List.fromList([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b])));
    sigAlg.add(ASN1Null());
    tbsCert.add(sigAlg);
    tbsCert.add(_buildName('MiBoxRemote'));
    final now = DateTime.now().toUtc();
    final validity = ASN1Sequence();
    validity.add(ASN1UtcTime(now));
    validity.add(ASN1UtcTime(now.add(const Duration(days: 3650))));
    tbsCert.add(validity);
    tbsCert.add(_buildName('MiBoxRemote'));
    tbsCert.add(_buildPublicKeyInfo(keyPair.publicKey));

    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(keyPair.privateKey));
    final sig = signer.generateSignature(tbsCert.encodedBytes) as RSASignature;

    final cert = ASN1Sequence();
    cert.add(tbsCert);
    cert.add(sigAlg);
    cert.add(ASN1BitString(Uint8List.fromList([0, ...sig.bytes])));

    final b64 = base64.encode(cert.encodedBytes);
    final lines = ['-----BEGIN CERTIFICATE-----'];
    for (var i = 0; i < b64.length; i += 64) {
      lines.add(b64.substring(i, min(i + 64, b64.length)));
    }
    lines.add('-----END CERTIFICATE-----');
    return lines.join('\n');
  }

  static ASN1Sequence _buildName(String cn) {
    final rdnSeq = ASN1Sequence();
    final rdn = ASN1Set();
    final atv = ASN1Sequence();
    atv.add(ASN1ObjectIdentifier.fromBytes(Uint8List.fromList([0x06,0x03,0x55,0x04,0x03])));
    atv.add(ASN1UTF8String(utf8String: cn));
    rdn.add(atv);
    rdnSeq.add(rdn);
    return rdnSeq;
  }

  static ASN1Sequence _buildPublicKeyInfo(RSAPublicKey publicKey) {
    final spki = ASN1Sequence();
    final alg = ASN1Sequence();
    alg.add(ASN1ObjectIdentifier.fromBytes(Uint8List.fromList([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01])));
    alg.add(ASN1Null());
    spki.add(alg);
    final pubKeySeq = ASN1Sequence();
    pubKeySeq.add(ASN1Integer(publicKey.modulus!));
    pubKeySeq.add(ASN1Integer(publicKey.exponent!));
    spki.add(ASN1BitString(Uint8List.fromList([0, ...pubKeySeq.encodedBytes])));
    return spki;
  }

  static String _encodePrivateKeyToPem(RSAPrivateKey pk) {
    final seq = ASN1Sequence();
    seq.add(ASN1Integer(BigInt.zero));
    seq.add(ASN1Integer(pk.modulus!));
    seq.add(ASN1Integer(pk.exponent!));
    seq.add(ASN1Integer(pk.privateExponent!));
    seq.add(ASN1Integer(pk.p!));
    seq.add(ASN1Integer(pk.q!));
    seq.add(ASN1Integer(pk.privateExponent! % (pk.p! - BigInt.one)));
    seq.add(ASN1Integer(pk.privateExponent! % (pk.q! - BigInt.one)));
    seq.add(ASN1Integer(pk.q!.modInverse(pk.p!)));
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
      final seq = ASN1Parser(der).nextObject() as ASN1Sequence;
      final tbs = seq.elements![0] as ASN1Sequence;
      final spki = tbs.elements![6] as ASN1Sequence;
      final bitStr = spki.elements![1] as ASN1BitString;
      final pubKeySeq = ASN1Parser(bitStr.contentBytes().sublist(1)).nextObject() as ASN1Sequence;
      return _bigIntToBytes((pubKeySeq.elements![0] as ASN1Integer).integer!);
    } catch (e) { return Uint8List(0); }
  }

  static Uint8List _extractExponentFromDer(Uint8List der) {
    try {
      final seq = ASN1Parser(der).nextObject() as ASN1Sequence;
      final tbs = seq.elements![0] as ASN1Sequence;
      final spki = tbs.elements![6] as ASN1Sequence;
      final bitStr = spki.elements![1] as ASN1BitString;
      final pubKeySeq = ASN1Parser(bitStr.contentBytes().sublist(1)).nextObject() as ASN1Sequence;
      return _bigIntToBytes((pubKeySeq.elements![1] as ASN1Integer).integer!);
    } catch (e) { return Uint8List(0); }
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

// ── Proto Writer ─────────────────────────────────────────────────────────
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
