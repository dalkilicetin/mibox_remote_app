import Foundation
import Security

enum KeychainHelper {

    // MARK: - Raw DER storage (kSecClassGenericPassword — en güvenilir)

    private static let certDERPrefix = "mibox_cert_der_"
    private static let keyDERPrefix  = "mibox_key_der_"

    static func storeCertAndKey(ip: String, certDER: Data, keyDER: Data) {
        saveData(certDER, account: certDERPrefix + ip)
        saveData(keyDER,  account: keyDERPrefix  + ip)
    }

    static func deleteCertAndKey(ip: String) {
        deleteData(account: certDERPrefix + ip)
        deleteData(account: keyDERPrefix  + ip)
    }

    static func hasCert(ip: String) -> Bool {
        loadData(account: certDERPrefix + ip) != nil
    }

    // MARK: - Identity reconstruction

    static func loadIdentity(label: String) -> SecIdentity? {
        let ip = String(label.dropFirst("mibox_identity_".count))
        guard !ip.isEmpty,
              let certDER = loadData(account: certDERPrefix + ip),
              let keyDER  = loadData(account: keyDERPrefix  + ip) else {
            print("[Keychain] DER data bulunamadı: \(label)")
            return nil
        }

        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            print("[Keychain] SecCertificate reconstruct başarısız")
            return nil
        }

        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String:       kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String:      kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var cfErr: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(keyDER as CFData, keyAttrs as CFDictionary, &cfErr) else {
            print("[Keychain] SecKey reconstruct başarısız: \(cfErr?.takeRetainedValue() as Any)")
            return nil
        }

        // Cert+key'i geçici olarak keychain'e koy, hemen identity olarak yükle
        let tempLabel = "mibox_temp_id_\(ip)"
        deleteIdentityItems(label: tempLabel)

        let certQ: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert, kSecAttrLabel as String: tempLabel]
        let cs = SecItemAdd(certQ as CFDictionary, nil)

        let keyQ: [String: Any] = [kSecClass as String: kSecClassKey, kSecValueRef as String: privateKey,
                                    kSecAttrLabel as String: tempLabel, kSecAttrIsPermanent as String: true,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let ks = SecItemAdd(keyQ as CFDictionary, nil)

        guard cs == errSecSuccess || cs == errSecDuplicateItem,
              ks == errSecSuccess || ks == errSecDuplicateItem else {
            print("[Keychain] temp cert/key eklenemedi cs=\(cs) ks=\(ks)")
            deleteIdentityItems(label: tempLabel)
            return nil
        }

        let idQ: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: tempLabel,
                                   kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var idRef: CFTypeRef?
        guard SecItemCopyMatching(idQ as CFDictionary, &idRef) == errSecSuccess, idRef != nil else {
            print("[Keychain] identity yüklenemedi")
            deleteIdentityItems(label: tempLabel)
            return nil
        }
        return (idRef as! SecIdentity)
    }

    static func identityLabel(ip: String) -> String { "mibox_identity_\(ip)" }

    // Pairing TLS için: cert+key'den anında identity üret (geçici keychain kaydı)
    static func buildTempIdentity(cert: SecCertificate, privateKey: SecKey, label: String) -> SecIdentity? {
        deleteIdentityItems(label: label)
        let certQ: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert, kSecAttrLabel as String: label]
        let keyQ:  [String: Any] = [kSecClass as String: kSecClassKey, kSecValueRef as String: privateKey,
                                     kSecAttrLabel as String: label, kSecAttrIsPermanent as String: true,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let cs = SecItemAdd(certQ as CFDictionary, nil)
        let ks = SecItemAdd(keyQ  as CFDictionary, nil)
        guard cs == errSecSuccess || cs == errSecDuplicateItem,
              ks == errSecSuccess || ks == errSecDuplicateItem else { return nil }
        let idQ: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: label,
                                   kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var ref: CFTypeRef?
        guard SecItemCopyMatching(idQ as CFDictionary, &ref) == errSecSuccess else { return nil }
        return (ref as! SecIdentity)
    }

    static func deleteTempIdentity(label: String) { deleteIdentityItems(label: label) }

    private static func deleteIdentityItems(label: String) {
        SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: label] as CFDictionary)
        SecItemDelete([kSecClass: kSecClassKey,         kSecAttrLabel: label] as CFDictionary)
    }

    // MARK: - Generic password helpers

    private static func saveData(_ data: Data, account: String) {
        deleteData(account: account)
        let q: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrAccount as String:     account,
            kSecValueData as String:       data,
            kSecAttrAccessible as String:  kSecAttrAccessibleAfterFirstUnlock,
        ]
        let s = SecItemAdd(q as CFDictionary, nil)
        if s != errSecSuccess { print("[Keychain] saveData '\(account)' failed: \(s)") }
    }

    private static func loadData(account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func deleteData(account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: account] as CFDictionary)
    }

    // MARK: - UserDefaults

    static func saveInt(_ v: Int,    key: String) { UserDefaults.standard.set(v, forKey: key) }
    static func saveStr(_ v: String, key: String) { UserDefaults.standard.set(v, forKey: key) }
    static func loadInt(_ key: String, def: Int)  -> Int    { let v = UserDefaults.standard.integer(forKey: key); return v == 0 ? def : v }
    static func loadStr(_ key: String)            -> String? { UserDefaults.standard.string(forKey: key) }

    static func pairingPortKey(ip: String) -> String { "atv_pairing_port_\(ip)" }
    static func remotePortKey(ip: String)  -> String { "atv_remote_port_\(ip)" }
}
