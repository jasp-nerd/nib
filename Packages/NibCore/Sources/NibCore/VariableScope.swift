import Foundation

/// The layered variable lookup used when resolving `{{name}}` placeholders.
///
/// Resolution order is request -> environment -> folder -> collection. The first layer
/// that defines a name wins.
///
/// The important and non-obvious part is that **environment beats collection**, matching
/// Postman's own precedence. The collection defines defaults (`baseUrl` = production);
/// the active environment is the user's "which target am I hitting" switch and has to be
/// able to override them. Ordering it the other way round would mean selecting the
/// Staging environment silently failed to redirect a request whose `baseUrl` came from
/// the collection — which is the single most common thing anyone does with environments.
///
/// `request` still wins over everything, because a per-request override is the most
/// specific statement of intent available.
public struct VariableScope: Sendable, Equatable {
    /// Ordered highest-precedence-first. The `Int` raw values define precedence, so adding
    /// a layer later means inserting it at the right number rather than rewriting lookup.
    public enum Layer: Int, Sendable, CaseIterable, Comparable {
        case request = 0
        case environment = 1
        case folder = 2
        case collection = 3

        public static func < (lhs: Layer, rhs: Layer) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private var storage: [Layer: [String: String]]

    public init() {
        storage = [:]
    }

    public init(_ layers: [Layer: [String: String]]) {
        storage = layers
    }

    /// Convenience for the common single-layer case, mostly in tests.
    public static func environment(_ values: [String: String]) -> VariableScope {
        VariableScope([.environment: values])
    }

    public mutating func set(_ values: [String: String], for layer: Layer) {
        storage[layer] = values
    }

    public mutating func set(_ value: String, forName name: String, in layer: Layer) {
        storage[layer, default: [:]][name] = value
    }

    public func values(for layer: Layer) -> [String: String] {
        storage[layer] ?? [:]
    }

    /// The winning value for `name`, searching narrowest layer first.
    public func value(for name: String) -> String? {
        for layer in Layer.allCases.sorted() {
            if let value = storage[layer]?[name] {
                return value
            }
        }
        return nil
    }

    /// Which layer supplied the winning value. Drives the "defined in Staging" hint in
    /// the URL field's completion menu.
    public func definingLayer(for name: String) -> Layer? {
        for layer in Layer.allCases.sorted() where storage[layer]?[name] != nil {
            return layer
        }
        return nil
    }

    /// Every name visible in this scope, deduplicated. Used for autocompletion.
    public var allNames: Set<String> {
        storage.values.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
    }
}
