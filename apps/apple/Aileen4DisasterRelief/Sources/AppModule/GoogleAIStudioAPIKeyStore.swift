import Foundation
import Security

enum GoogleAIStudioAPIKeyStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Google AI Studio keychain access failed with status \(status)."
        }
    }
}

struct GoogleAIStudioAPIKeyStore {
    private let service = (Bundle.main.bundleIdentifier ?? "Aileen4DisasterRelief") + ".credentials"
    private let account = "google-ai-studio-api-key"

    func load() throws -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return ""
            }
            return value
        case errSecItemNotFound:
            return ""
        default:
            throw GoogleAIStudioAPIKeyStoreError.unexpectedStatus(status)
        }
    }

    func save(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete()
            return
        }

        try delete()

        var item = baseQuery()
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GoogleAIStudioAPIKeyStoreError.unexpectedStatus(status)
        }
    }

    private func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleAIStudioAPIKeyStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
