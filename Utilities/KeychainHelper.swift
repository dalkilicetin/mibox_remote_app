import Foundation
import Security

enum KeychainHelper {

    // MARK: - Raw DER storage (kSecClassGenericPassword)
    // Key olarak MAC adresi kullanıyoruz (IP değişebilir, MAC değişmez).
    // MAC yoksa fallback olarak IP kullanılır.

    private static let certDERPrefix = "mibox_cert_der_"
    private static let keyDERPrefix  = "mibox_key_der_"

    static func storeCertAndKey(certKey: String, certDER: Data, keyDER: Data) {
        saveData(certDER, account: certDERPrefix + certKey)
        saveData(keyDER,  account: keyDERPrefix  + certKey)
    }

    static func deleteCertAndKey(certKey: String) {
        deleteData(account: certDERPrefix + certKey)
        deleteData(account: keyDERPrefix  + certKey)
    }

    static func hasCert(certKey: String) -> Bool {
        loadData(account: certDERPrefix + certKey) != nil
    }

    // MARK: - Identity reconstruction

    static func loadIdentity(certKey: String) -> SecIdentity? {
        guard !certKey.isEmpty,
              let certDER = loadData(account: certDERPrefix + certKey),
              let keyDER  = loadData(account: keyDERPrefix  + certKey) else {
            print("[Keychain] DER data bulunamadı: \(certKey)")
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

        let tempLabel = "mibox_temp_id_\(certKey)"
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
        // Temp items'ı temizle — SecIdentity artık bellekte
        deleteIdentityItems(label: tempLabel)
        return (idRef as! SecIdentity)
    }

    // Pairing TLS için geçici identity
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

    // MARK: - TV sertifikasından MAC parse et
    // TV cert CN örneği: "atvremote/darcy/darcy/SHIELD Android TV/AA:BB:CC:DD:EE:FF"
    // veya DNQualifier: "fugu/fugu/Nexus Player/CN=atvremote/AA:BB:CC:DD:EE:FF"
    static func macFromServerCert(_ cert: SecCertificate) -> String? {
        guard let summary = SecCertificateCopySubjectSummary(cert) as String? else { return nil }
        // CN veya DNQualifier'ın son segmenti MAC adresi
        let parts = summary.split(separator: "/").map { String($0) }
        for part in parts.reversed() {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            // MAC formatı: XX:XX:XX:XX:XX:XX
            if trimmed.count == 17,
               trimmed.filter({ $0 == ":" }).count == 5,
               trimmed.allSatisfy({ $0.isHexDigit || $0 == ":" }) {
                return trimmed.uppercased()
            }
        }
        // Fallback: summary'nin tamamına hex+colon regex uygula
        let pattern = "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}"
        if let range = summary.range(of: pattern, options: .regularExpression) {
            return String(summary[range]).uppercased()
        }
        return nil
    }

    // MARK: - UserDefaults (port ve IP cache)
    // Port key'leri de certKey (MAC) bazlı

    static func saveInt(_ v: Int,    key: String) { UserDefaults.standard.set(v, forKey: key) }
    static func saveStr(_ v: String, key: String) { UserDefaults.standard.set(v, forKey: key) }
    static func loadInt(_ key: String, def: Int)  -> Int    { let v = UserDefaults.standard.integer(forKey: key); return v == 0 ? def : v }
    static func loadStr(_ key: String)            -> String? { UserDefaults.standard.string(forKey: key) }

    // certKey (MAC veya IP) bazlı port kayıt
    static func pairingPortKey(certKey: String) -> String { "atv_pairing_port_\(certKey)" }
    static func remotePortKey(certKey: String)  -> String { "atv_remote_port_\(certKey)" }

    // Geriye dönük uyumluluk (eski IP bazlı key'ler için — migration)
    static func migrateLegacyKeys(fromIP ip: String, toMac mac: String) {
        // Eski IP bazlı cert/key varsa MAC'e taşı
        if let certDER = loadData(account: certDERPrefix + ip),
           let keyDER  = loadData(account: keyDERPrefix  + ip) {
            storeCertAndKey(certKey: mac, certDER: certDER, keyDER: keyDER)
            deleteData(account: certDERPrefix + ip)
            deleteData(account: keyDERPrefix  + ip)
            print("[Keychain] Migration: \(ip) → \(mac)")
        }
        // Port kayıtlarını da taşı
        let pPort = UserDefaults.standard.integer(forKey: "atv_pairing_port_\(ip)")
        let rPort = UserDefaults.standard.integer(forKey: "atv_remote_port_\(ip)")
        if pPort != 0 { UserDefaults.standard.set(pPort, forKey: pairingPortKey(certKey: mac)) }
        if rPort != 0 { UserDefaults.standard.set(rPort, forKey: remotePortKey(certKey: mac)) }
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
}
