import Foundation
import Security
import CryptoKit

enum CertificateHelper {
    struct KeyPair {
        let privateKey: SecKey
        let publicKey:  SecKey
        let publicKeyDER: Data   // PKCS#1 RSAPublicKey DER
    }

    // MARK: - Key generation

    static func generateRSAKeyPair() throws -> KeyPair {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String:       kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String:   [kSecAttrIsPermanent as String: false],
        ]
        var err: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
            throw err!.takeRetainedValue() as Error
        }
        guard let pub = SecKeyCopyPublicKey(priv) else {
            throw NSError(domain: "CertHelper", code: 1)
        }
        var expErr: Unmanaged<CFError>?
        guard let pubDER = SecKeyCopyExternalRepresentation(pub, &expErr) as Data? else {
            throw expErr!.takeRetainedValue() as Error
        }
        return KeyPair(privateKey: priv, publicKey: pub, publicKeyDER: pubDER)
    }

    // MARK: - Self-signed X.509

    static func createSelfSignedCert(keyPair: KeyPair, cn: String = "com.mibox.remote") throws -> SecCertificate {
        let now = Date()
        let name = DEREncoder.sequence(
            DEREncoder.setOf(
                DEREncoder.sequence(
                    DEREncoder.oid(DEREncoder.oidCommonName),
                    DEREncoder.utf8String(cn)
                )
            )
        )

        let spki = DEREncoder.sequence(
            DEREncoder.sequence(
                DEREncoder.oid(DEREncoder.oidRSAEncryption),
                DEREncoder.null()
            ),
            DEREncoder.bitString(keyPair.publicKeyDER)
        )

        let serial: [UInt8] = (0..<8).map { _ in UInt8.random(in: 1...255) }
        let sigAlg = DEREncoder.sequence(
            DEREncoder.oid(DEREncoder.oidSHA256WithRSA),
            DEREncoder.null()
        )

        let tbs = DEREncoder.sequence(
            DEREncoder.contextExplicit(0, DEREncoder.integer([2])),
            DEREncoder.integer(serial),
            sigAlg,
            name,
            DEREncoder.sequence(
                DEREncoder.utcTime(now.addingTimeInterval(-86400)),
                DEREncoder.utcTime(now.addingTimeInterval(3650 * 86400))
            ),
            name,
            spki
        )

        var signErr: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            keyPair.privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbs as CFData,
            &signErr
        ) as Data? else {
            throw signErr!.takeRetainedValue() as Error
        }

        let certDER = DEREncoder.sequence(tbs, sigAlg, DEREncoder.bitString(sig))
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw NSError(domain: "CertHelper", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "SecCertificateCreateWithData failed"])
        }
        return cert
    }

    // MARK: - RSA component extraction

    static func rsaComponents(from publicKey: SecKey) -> (modulus: Data, exponent: Data)? {
        var err: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(publicKey, &err) as Data? else { return nil }
        return DERParser.parseRSAPublicKey(der)
    }

    static func rsaComponents(from cert: SecCertificate) -> (modulus: Data, exponent: Data)? {
        guard let key = SecCertificateCopyKey(cert) else { return nil }
        return rsaComponents(from: key)
    }
}
