import Foundation

/// A stable identifier that survives renames.
///
/// Filenames are the display name, so renaming a request in Finder renames it in Nib. That means the
/// name cannot be the identity — history, open tabs and selection all have to stay attached across a
/// rename. A ULID-shaped string is used rather than `UUID` because it sorts lexicographically by
/// creation time, which makes a directory listing of ids readable.
public struct NodeID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Generate a new identifier.
    ///
    /// Takes the timestamp and randomness as parameters so callers in tests can be deterministic —
    /// the on-disk determinism invariant means a test that writes a file twice must be able to
    /// produce the same bytes twice.
    public static func generate(
        millisecondsSinceEpoch: UInt64,
        random: (Int) -> [UInt8] = Self.randomBytes
    ) -> NodeID {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)  // Crockford base32
        var characters: [UInt8] = []
        characters.reserveCapacity(26)

        // 48 bits of timestamp, 10 characters.
        var timestamp = millisecondsSinceEpoch
        var timeCharacters: [UInt8] = []
        for _ in 0..<10 {
            timeCharacters.append(alphabet[Int(timestamp % 32)])
            timestamp /= 32
        }
        characters.append(contentsOf: timeCharacters.reversed())

        // 80 bits of randomness, 16 characters.
        for byte in random(16) {
            characters.append(alphabet[Int(byte % 32)])
        }

        return NodeID(rawValue: String(decoding: characters, as: UTF8.self))
    }

    public static func generate() -> NodeID {
        generate(millisecondsSinceEpoch: UInt64(Date().timeIntervalSince1970 * 1000))
    }

    /// Not private: it is a default argument of `generate`, which makes it part of the public
    /// interface whether we like it or not.
    public static func randomBytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: 0...255) }
    }

    public var description: String { rawValue }
}

/// One entry in a collection: either a request or a folder containing more entries.
public enum CollectionNode: Sendable, Hashable, Identifiable {
    case request(RequestNode)
    case folder(FolderNode)

    public var id: NodeID {
        switch self {
        case .request(let node): node.id
        case .folder(let node): node.id
        }
    }

    /// The display name, which is also the filename on disk.
    public var name: String {
        switch self {
        case .request(let node): node.name
        case .folder(let node): node.name
        }
    }

    public var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }

    /// Children, for a folder. `nil` for a request, which is how the sidebar knows whether to draw a
    /// disclosure triangle at all — an empty folder still gets one, a request never does.
    public var children: [CollectionNode]? {
        switch self {
        case .request: nil
        case .folder(let node): node.children
        }
    }
}

public struct RequestNode: Sendable, Hashable, Identifiable {
    public var id: NodeID
    /// Display name and filename stem. Not the identity — see `NodeID`.
    public var name: String
    public var spec: HTTPRequestSpec

    public init(id: NodeID = .generate(), name: String, spec: HTTPRequestSpec) {
        self.id = id
        self.name = name
        self.spec = spec
    }
}

public struct FolderNode: Sendable, Hashable, Identifiable {
    public var id: NodeID
    public var name: String
    public var children: [CollectionNode]
    /// Folder-level auth, inherited by requests that say `.inherit`.
    public var auth: AuthSpec
    public var variables: [EnvironmentVariable]

    public init(
        id: NodeID = .generate(),
        name: String,
        children: [CollectionNode] = [],
        auth: AuthSpec = .none,
        variables: [EnvironmentVariable] = []
    ) {
        self.id = id
        self.name = name
        self.children = children
        self.auth = auth
        self.variables = variables
    }
}

/// A whole collection: the root of the tree plus its own defaults.
public struct Collection: Sendable, Hashable, Identifiable {
    /// Stable across clones, and the namespace for Keychain accounts. A repo cloned onto another
    /// machine keeps this id, so it looks for the same secret entries — and correctly finds nothing.
    public var id: NodeID
    public var name: String
    public var children: [CollectionNode]
    public var auth: AuthSpec
    public var variables: [EnvironmentVariable]

    public init(
        id: NodeID = .generate(),
        name: String,
        children: [CollectionNode] = [],
        auth: AuthSpec = .none,
        variables: [EnvironmentVariable] = []
    ) {
        self.id = id
        self.name = name
        self.children = children
        self.auth = auth
        self.variables = variables
    }
}

/// A collection or environment variable.
public struct EnvironmentVariable: Sendable, Hashable, Codable {
    public var key: String
    /// `nil` when the value is secret. The value lives in the Keychain and never on disk — see
    /// `StoreLocations.keychainService`.
    public var value: String?
    public var secret: Bool
    public var enabled: Bool

    public init(key: String, value: String?, secret: Bool = false, enabled: Bool = true) {
        self.key = key
        self.value = value
        self.secret = secret
        self.enabled = enabled
    }
}

/// A named set of variables.
public struct Environment: Sendable, Hashable, Identifiable {
    public var id: NodeID
    public var name: String
    public var variables: [EnvironmentVariable]

    public init(id: NodeID = .generate(), name: String, variables: [EnvironmentVariable] = []) {
        self.id = id
        self.name = name
        self.variables = variables
    }
}

// MARK: - Traversal

extension Collection {
    /// Every request in the tree, depth-first, paired with its folder path.
    ///
    /// Used by the `⌘K` switcher and by anything that needs to resolve inherited auth, so it returns
    /// the ancestor chain rather than just the leaf.
    public var allRequests: [(request: RequestNode, path: [FolderNode])] {
        Self.collectRequests(in: children, path: [])
    }

    private static func collectRequests(
        in nodes: [CollectionNode],
        path: [FolderNode]
    ) -> [(request: RequestNode, path: [FolderNode])] {
        nodes.flatMap { node -> [(request: RequestNode, path: [FolderNode])] in
            switch node {
            case .request(let request):
                [(request, path)]
            case .folder(let folder):
                collectRequests(in: folder.children, path: path + [folder])
            }
        }
    }

    /// Resolve the auth a request inherits, innermost folder first, then the collection.
    ///
    /// Mirrors variable precedence: the most specific statement of intent wins.
    public func inheritedAuth(forRequestAt path: [FolderNode]) -> AuthSpec {
        for folder in path.reversed() where folder.auth != .none {
            return folder.auth
        }
        return auth
    }

    /// Find a request by id, anywhere in the tree.
    public func request(withID id: NodeID) -> RequestNode? {
        allRequests.first { $0.request.id == id }?.request
    }
}

// MARK: - Explicit encoding for EnvironmentVariable

extension EnvironmentVariable {
    private enum CodingKeys: String, CodingKey { case key, value, secret, enabled }

    /// Always writes `value`, using `null` for a secret.
    ///
    /// Swift's default encoding *omits* a nil optional, which would make a secret's key disappear from
    /// the file entirely — indistinguishable from never having existed. The documented format is
    /// `"value": null` precisely so a clone on another machine can see the key, find nothing in its
    /// Keychain, and prompt. An absent key could not do that.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        if let value {
            try container.encode(value, forKey: .value)
        } else {
            try container.encodeNil(forKey: .value)
        }
        try container.encode(secret, forKey: .secret)
        try container.encode(enabled, forKey: .enabled)
    }
}
