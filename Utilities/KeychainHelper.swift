import Foundation
import Security

enum KeychainHelper {

    // MARK: - Identity (SecCertificate + SecKey)

    @discardableResult
    static func storeIdentity(cert: SecCertificate, privateKey: SecKey, label: String) -> Bool {
        deleteIdentity(label: label)

        // kSecAttrAccessible is NOT used for certificates — iOS ignores or rejects it
        let certQ: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: label,
        ]
        let cs = SecItemAdd(certQ as CFDictionary, nil)
        guard cs == errSecSuccess || cs == errSecDuplicateItem else {
            print("[Keychain] cert add failed: \(cs)")
            return false
        }

        let keyQ: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrLabel as String: label,
            kSecAttrIsPermanent as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let ks = SecItemAdd(keyQ as CFDictionary, nil)
        guard ks == errSecSuccess || ks == errSecDuplicateItem else {
            print("[Keychain] key add failed: \(ks)")
            return false
        }
        return true
    }

    static func loadIdentity(label: String) -> SecIdentity? {
        // Primary: query identity directly by certificate label
        let q: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, result != nil {
            return (result as! SecIdentity)
        }

        // Fallback: get cert by label → search identity matching that cert
        let certQ: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var certRef: CFTypeRef?
        guard SecItemCopyMatching(certQ as CFDictionary, &certRef) == errSecSuccess,
              let cert = certRef else {
            print("[Keychain] cert not found for label: \(label)")
            return nil
        }
        let idQ: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchItemList as String: [cert as! SecCertificate],
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var idRef: CFTypeRef?
        guard SecItemCopyMatching(idQ as CFDictionary, &idRef) == errSecSuccess else {
            print("[Keychain] identity not found via cert match")
            return nil
        }
        return (idRef as! SecIdentity)
    }

    static func hasCert(ip: String) -> Bool {
        loadIdentity(label: identityLabel(ip: ip)) != nil
    }

    static func deleteIdentity(label: String) {
        SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: label] as CFDictionary)
        SecItemDelete([kSecClass: kSecClassKey,         kSecAttrLabel: label] as CFDictionary)
    }

    static func identityLabel(ip: String) -> String { "mibox_identity_\(ip)" }

    // MARK: - UserDefaults

    static func saveInt(_ v: Int,    key: String) { UserDefaults.standard.set(v,      forKey: key) }
    static func saveStr(_ v: String, key: String) { UserDefaults.standard.set(v,      forKey: key) }
    static func loadInt(_ key: String, def: Int)  -> Int    { let v = UserDefaults.standard.integer(forKey: key); return v == 0 ? def : v }
    static func loadStr(_ key: String)            -> String? { UserDefaults.standard.string(forKey: key) }

    static func pairingPortKey(ip: String) -> String { "atv_pairing_port_\(ip)" }
    static func remotePortKey(ip: String)  -> String { "atv_remote_port_\(ip)" }
}
