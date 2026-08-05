import Foundation
import NibCore
import Security

/// The Keychain half of an environment.
///
/// INVARIANT (see `StoreLocations`): a secret's value is never written into the collection
/// folder. The file records the key with `"value": null`; the value lives here, keyed by
/// `<collectionID>/<environmentName>/<key>`.
///
/// That account format is deliberately human-readable rather than a hash. Keychain Access is
/// the escape hatch when Nib is not running — a user who wants to read, rotate or delete
/// their own token should be able to find it by eye, and a hashed account would make the
/// Keychain a place secrets go to disappear.
///
/// Two honest limitations, both consequences of shipping self-signed:
///
///   - This is the **file-based** keychain, not the data-protection keychain. The modern one
///     needs a `keychain-access-groups` entitlement tied to a Team ID, which a self-signed
///     build does not have — `SecItemAdd` returns `errSecMissingEntitlement` there.
///   - The file keychain's ACL is bound to the code signature. An ad-hoc signature changes
///     with every build, so upgrading Nib can prompt for permission again. Clicking "Always
///     Allow" holds until the next upgrade. Notarizing with a stable Developer ID would end
///     this; it is one of the costs of the signing choice, not a bug to fix here.
///
/// An `actor` because every call below is a blocking C function that can wait on the user
/// dismissing a permission dialog. Off the main actor is the only correct place for it.
public actor SecretStore {

    /// A Keychain call failed for a reason the caller has to know about.
    ///
    /// Deliberately not swallowed into an optional. "Could not read the Keychain" and "there is
    /// no secret stored" have to stay distinguishable, because the first one must never be
    /// allowed to look like the second — treating a locked Keychain as "no secrets" is how you
    /// delete somebody's tokens on the next save.
    public struct SecretError: Error, Sendable, Equatable, CustomStringConvertible {
        public let status: OSStatus
        public let operation: String

        public var description: String {
            let reason =
                SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain error \(status)"
            return "\(operation): \(reason)"
        }
    }

    public let service: String

    /// `service` is injectable so tests get their own namespace and can never see, overwrite or
    /// delete a real secret belonging to the person running them.
    public init(service: String = StoreLocations.keychainService) {
        self.service = service
    }

    // MARK: - Account naming

    /// Everything belonging to one collection shares this prefix, which is what makes
    /// "reconcile the whole collection at once" possible in a single query.
    public static func prefix(collectionID: NodeID) -> String {
        "\(collectionID.rawValue)/"
    }

    public static func account(
        collectionID: NodeID,
        environmentName: String,
        key: String
    ) -> String {
        "\(prefix(collectionID: collectionID))\(environmentName)/\(key)"
    }

    // MARK: - Single values

    public func value(for account: String) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query(account: account, returning: [kSecReturnData: true]) as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw SecretError(status: status, operation: "Reading \(account)")
        }
    }

    /// Store or replace a value.
    ///
    /// `SecItemAdd` fails with `errSecDuplicateItem` rather than overwriting, so the update path
    /// is not an optimisation — it is the only way a second save works at all.
    public func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        var attributes = query(account: account)
        attributes[kSecValueData] = data
        // Unlocked-only: a secret this app sends over the network has no business being
        // readable while the machine is locked.
        attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = SecItemUpdate(
                query(account: account) as CFDictionary,
                [kSecValueData: data] as CFDictionary)
            guard update == errSecSuccess else {
                throw SecretError(status: update, operation: "Updating \(account)")
            }
        default:
            throw SecretError(status: status, operation: "Storing \(account)")
        }
    }

    /// Delete a value. Deleting something that is not there is a success, not an error.
    public func remove(_ account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretError(status: status, operation: "Deleting \(account)")
        }
    }

    // MARK: - Whole-collection operations

    /// Which accounts exist under `prefix`.
    ///
    /// Attributes only, deliberately. The file-based keychain rejects `kSecMatchLimitAll`
    /// together with `kSecReturnData` outright — it answers `errSecParam`, not an empty list —
    /// so bulk-reading values in one call is simply not available to us here. Enumerating names
    /// is, and it is all the reconcile path needs.
    public func accounts(withPrefix prefix: String) throws -> Set<String> {
        var result: CFTypeRef?
        var search = query()
        search[kSecMatchLimit] = kSecMatchLimitAll
        search[kSecReturnAttributes] = true

        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw SecretError(status: status, operation: "Listing secrets for \(prefix)")
        }

        let items = result as? [[CFString: Any]] ?? []
        return Set(
            items.compactMap { $0[kSecAttrAccount] as? String }.filter { $0.hasPrefix(prefix) })
    }

    /// Every stored account under `prefix`, with its value.
    ///
    /// One read per account, for the reason above. Called once when a collection opens, not per
    /// send — the values are held in memory from then on, because they have to be to build a
    /// request at all.
    public func load(prefix: String) throws -> [String: String] {
        var values: [String: String] = [:]
        for account in try accounts(withPrefix: prefix) {
            if let value = try value(for: account) {
                values[account] = value
            }
        }
        return values
    }

    /// Make the Keychain match `entries` exactly, for accounts under `prefix`.
    ///
    /// This is what handles the cases a per-variable write cannot: renaming an environment,
    /// deleting one, or unticking "secret" on a variable all have to leave the old entry gone
    /// rather than orphaned in the user's Keychain forever.
    ///
    /// The listing happens first and its failure propagates *before* anything is written or
    /// deleted. A locked Keychain listing as empty would make this method delete every secret
    /// the user has, which is the worst thing in this file that could possibly happen.
    public func synchronise(prefix: String, entries: [String: String]) throws {
        let existing = try accounts(withPrefix: prefix)

        // Written unconditionally rather than compared first. Comparing would cost a read per
        // account for no benefit: `set` already collapses to an update, and a Keychain write of
        // an unchanged value is not observable to anyone.
        for (account, value) in entries {
            try set(value, for: account)
        }

        for account in existing where entries[account] == nil {
            try remove(account)
        }
    }

    // MARK: - Queries

    private func query(
        account: String? = nil,
        returning extras: [CFString: Any] = [:]
    ) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        if let account { query[kSecAttrAccount] = account }
        query.merge(extras) { _, new in new }
        return query
    }
}
