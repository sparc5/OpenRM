//
//  CredentialStore.swift
//  OpenRM
//
//  Keychain storage for clientId + masterPairKey so we don't re-pair every session.
//

import Foundation
import Security

struct CPAPCredentials: Codable {
    let clientId: String
    let masterPairKey: String
    // Peripheral UUID as String (UUID.uuidString). Optional for back-compat
    // with any pre-existing keychain entries from earlier builds.
    var peripheralId: String?
}

enum CredentialStore {
    private static let service = "com.openrm.cpap"
    private static let account = "airsense11"

    static func save(_ creds: CPAPCredentials) throws {
        let data = try JSONEncoder().encode(creds)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Delete existing then add
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            throw StoreError.osStatus(status)
        }
    }

    static func load() -> CPAPCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let creds = try? JSONDecoder().decode(CPAPCredentials.self, from: data) else {
            return nil
        }
        return creds
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum StoreError: Error {
        case osStatus(OSStatus)
    }
}
