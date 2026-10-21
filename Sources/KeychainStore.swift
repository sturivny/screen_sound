import Foundation
import Security
import LocalAuthentication

enum KeychainStore {
    private static let service = "local.screensound.recorder.openai"
    private static let account = "api-key"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func hasKey() -> Bool {
        var q = query
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
    static func save(_ value: String) throws {
        let key = try AIClient.validatedKey(value)
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            q[kSecAttrLabel as String] = "ScreenSound · OpenAI API"
            try check(SecItemAdd(q as CFDictionary, nil))
        } else { try check(status) }
    }
    static func read() throws -> String {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        try check(SecItemCopyMatching(q as CFDictionary, &result))
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw AIError(message: "The API key was not found in macOS Keychain.")
        }
        return try AIClient.validatedKey(key)
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw AIError(message: "Could not access macOS Keychain (code \(status)).")
        }
    }
}
