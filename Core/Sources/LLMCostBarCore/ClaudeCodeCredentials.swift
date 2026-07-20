import Foundation
import Security

public enum ClaudeCredentialState: Equatable, Sendable {
    case found(accessToken: String, subscriptionType: String?)
    case notFound                 // no keychain item, no credentials file → source undetected
    case denied(String)           // keychain access refused → stale with actionable reason
    case invalid(String)          // blob exists but doesn't parse → decode-class failure
}

/// Read-only accessor for Claude Code's own OAuth credentials. NEVER writes,
/// refreshes, or deletes the item — Claude Code owns the token lifecycle, and
/// rotating its refresh token from here would log the user out of Claude Code.
/// (Keychain approach borrowed from steipete/CodexBar, MIT.)
public enum ClaudeCodeCredentials {
    public static let service = "Claude Code-credentials"

    public static var defaultCredentialsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    /// Pure parse of the credential blob (keychain or file) — testable without Keychain.
    public static func parse(_ data: Data) -> ClaudeCredentialState {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return .invalid("credential blob: no claudeAiOauth.accessToken")
        }
        return .found(accessToken: token, subscriptionType: oauth["subscriptionType"] as? String)
    }

    /// Attributes-only query: existence check that never touches the protected
    /// data, so detection can run every poll without a consent prompt.
    public static func isDetected(credentialsFile: URL = defaultCredentialsFile) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess { return true }
        return FileManager.default.fileExists(atPath: credentialsFile.path)
    }

    /// First data read triggers the one-time macOS consent prompt ("Always Allow").
    public static func read(credentialsFile: URL = defaultCredentialsFile) -> ClaudeCredentialState {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .invalid("keychain returned non-data") }
            return parse(data)
        case errSecItemNotFound:
            guard let data = try? Data(contentsOf: credentialsFile) else { return .notFound }
            return parse(data)
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .denied("grant llmcostd access to '\(service)' in Keychain — click Always Allow")
        default:
            return .denied("keychain error \(status)")
        }
    }
}
