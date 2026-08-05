import Foundation
import Security

/// Is there a usable Keychain in this process, and how do I clean up after myself?
///
/// Shared because two test targets need the same answer — `NibStore` tests `SecretStore` directly
/// and `NibUI` tests the environment layer on top of it — and a second, slightly different copy of
/// this is exactly the kind of duplication that ends up disagreeing about what "usable" means.
///
/// Kept synchronous and free of any Nib type so it can be used from `.enabled(if:)`, which does
/// not accept an async condition.
public enum KeychainProbe {
    private static let probeService = "app.nib.secret.probe"

    /// A real round trip, not a guess.
    ///
    /// Tests that need the Keychain are skipped rather than failed when this is false. A locked
    /// login keychain or a CI runner without one is an environment difference, and a suite that
    /// goes red for that trains people to stop reading red.
    public static var isUsable: Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: probeService,
            kSecAttrAccount: "probe",
            kSecValueData: Data("probe".utf8),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }

    /// Wipe a test service. Never call this with the real service name.
    public static func deleteEverything(inService service: String) {
        SecItemDelete(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
            ] as CFDictionary)
    }
}
