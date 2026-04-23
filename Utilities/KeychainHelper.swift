import Foundation
import Security

enum KeychainHelper {

    // MARK: - Identity (SecCertificate + SecKey)

    @discardableResult
    static func storeIdentity(cert: SecCertificate, privateKey: SecKey, label: String) -> Bool {
        deleteIdentity(label: label)

        let certQ: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let cs = SecItemAdd(certQ as CFDictionary, nil)
        guard cs == errSecSuccess || cs == errSecDuplicateItem else {
            print("[Keychain] cert add: \(cs)")
            return false
        }

        let keyQ: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrLabel as String: label,
            kSecAttrIsPermanent as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let ks = SecItemAdd(keyQ as CFDictionary, nil)
        guard ks == errSecSuccess || ks == errSecDuplicateItem else {
            print("[Keychain] key add: \(ks)")
            return false
        }
        return true
    }

    static func loadIdentity(label: String) -> SecIdentity? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as! SecIdentity)
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
