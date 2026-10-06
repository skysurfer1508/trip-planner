import Foundation
import Security
import Observation

struct APIKeys: Sendable {
    var openTripMap = ""
    var tripadvisor = ""
    var gemini = ""
}

/// API keys the user enters in Settings. They live in the Keychain on this device only and are
/// never part of the source code or the repo.
@Observable
final class Secrets {
    var openTripMapKey = ""
    var tripadvisorKey = ""
    var geminiKey = ""

    init() {
        openTripMapKey = Keychain.read("opentripmap")
        tripadvisorKey = Keychain.read("tripadvisor")
        geminiKey = Keychain.read("gemini")
        // Claude is no longer used; remove a key saved by an earlier version.
        Keychain.write("", account: "anthropic")
    }

    var keys: APIKeys {
        APIKeys(openTripMap: openTripMapKey.trimmingCharacters(in: .whitespacesAndNewlines),
                tripadvisor: tripadvisorKey.trimmingCharacters(in: .whitespacesAndNewlines),
                gemini: geminiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var hasOpenTripMap: Bool { !keys.openTripMap.isEmpty }
    var hasTripadvisor: Bool { !keys.tripadvisor.isEmpty }
    var hasGemini: Bool { !keys.gemini.isEmpty }

    func persist() {
        Keychain.write(keys.openTripMap, account: "opentripmap")
        Keychain.write(keys.tripadvisor, account: "tripadvisor")
        Keychain.write(keys.gemini, account: "gemini")
    }
}

private enum Keychain {
    static let service = "com.skysurfer.TripPlanner"

    static func read(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
