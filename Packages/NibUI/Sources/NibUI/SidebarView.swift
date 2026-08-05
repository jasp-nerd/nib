import NibCore
import SwiftUI

/// The collection tree.
///
/// A SwiftUI `List` with `DisclosureGroup` for now. The plan flags that `List` degrades past a few
/// thousand rows, so this talks to the model through nothing but `collection` and `selectedRequestID`
/// — swapping in an `NSOutlineView` later needs no changes outside this file.
public struct SidebarView: View {
    @Bindable var model: CollectionModel

    @State private var filter = ""

    public init(model: CollectionModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let collection = model.collection {
                content(collection)
            } else {
                EmptyCollectionView(model: model)
            }
        }
    }

    @ViewBuilder
    private func content(_ collection: NibCore.Collection) -> some View {
        let matches = filtered(collection.children)

        List(selection: Binding($model.selectedRequestID)) {
            Section(collection.name) {
                ForEach(matches, id: \.id) { node in
                    NodeRow(node: node, model: model)
                }
            }
        }
        .listStyle(.sidebar)
        // Nothing matched is a different state from an empty collection, and saying which is
        // showing is the only way to tell "my filter is too narrow" from "this folder is empty".
        .overlay {
            if matches.isEmpty, !filter.isEmpty {
                ContentUnavailableView.search(text: filter)
            }
        }
        // `safeAreaBar` rather than a `VStack` row, and this is the macOS 26 part.
        //
        // A bar attached this way is chrome, not content: the system gives it the bar material,
        // keeps it out of the list's scrollable area, and — the reason it is worth changing —
        // gives the list a scroll edge effect, so rows fade out underneath the filter field
        // instead of sliding up to a hard divider and stopping. Stacking the field above the list
        // in a VStack gets none of that, because from SwiftUI's side it is just another row.
        .safeAreaBar(edge: .top) {
            // One bar, not two stacked ones: `safeAreaBar` supplies the material, and a second
            // bar underneath the first would paint one translucent layer over another.
            VStack(spacing: 0) {
                if !model.diagnostics.isEmpty {
                    DiagnosticsBanner(messages: model.diagnostics)
                }
                filterField
            }
        }
        .safeAreaBar(edge: .bottom) { footer }
    }

    private var filterField: some View {
        PaneBar(horizontal: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter", text: $filter)
                .textFieldStyle(.plain)
            if !filter.isEmpty {
                Button("Clear filter", systemImage: "xmark.circle.fill") { filter = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    // The clear button appearing is a state change, not decoration, so it gets a
                    // transition rather than popping into place.
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .animation(.smooth(duration: 0.16), value: filter.isEmpty)
    }

    private var footer: some View {
        PaneBar(horizontal: 10) {
            Button("New request", systemImage: "plus") {
                Task { await model.addRequest() }
            }
            .labelStyle(.iconOnly)
            .help("New request")

            Button("New folder", systemImage: "folder.badge.plus") {
                Task { await model.addFolder() }
            }
            .labelStyle(.iconOnly)
            .help("New folder")

            Spacer()

            if let root = model.rootURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([root])
                } label: {
                    Text(root.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Reveal \(root.path) in Finder")
            }
        }
        .buttonStyle(.borderless)
    }

    /// Filter the tree, keeping a folder whenever any descendant matches.
    ///
    /// Dropping a folder whose child matches would hide the match, which is the one thing a filter
    /// must never do.
    private func filtered(_ nodes: [CollectionNode]) -> [CollectionNode] {
        guard !filter.isEmpty else { return nodes }
        let needle = filter.lowercased()

        return nodes.compactMap { node in
            switch node {
            case .request(let request):
                return request.name.lowercased().contains(needle) ? node : nil
            case .folder(var folder):
                if folder.name.lowercased().contains(needle) { return node }
                let matching = filtered(folder.children)
                guard !matching.isEmpty else { return nil }
                folder.children = matching
                return .folder(folder)
            }
        }
    }
}

// MARK: - Rows

/// One node. Recursive, so a folder renders its own children.
private struct NodeRow: View {
    let node: CollectionNode
    var model: CollectionModel

    var body: some View {
        switch node {
        case .request(let request):
            RequestRow(request: request, model: model)
        case .folder(let folder):
            DisclosureGroup {
                ForEach(folder.children, id: \.id) { child in
                    NodeRow(node: child, model: model)
                }
            } label: {
                Label(folder.name, systemImage: "folder")
                    .contextMenu { NodeMenu(id: folder.id, model: model) }
            }
        }
    }
}

private struct RequestRow: View {
    let request: RequestNode
    var model: CollectionModel

    var body: some View {
        HStack(spacing: 6) {
            Text(request.spec.method.rawValue)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(MethodStyle.colour(for: request.spec.method))
                .frame(width: 38, alignment: .leading)
                // The colour is the only thing distinguishing these at a glance, so the method has
                // to be spoken as well as shown — colour alone is not an accessible signal.
                .accessibilityLabel("\(request.spec.method.rawValue) request")
            Text(request.name)
                .lineLimit(1)
        }
        .tag(request.id)
        .contextMenu { NodeMenu(id: request.id, model: model) }
    }
}

private struct NodeMenu: View {
    let id: NodeID
    var model: CollectionModel

    var body: some View {
        Button("Delete") {
            Task { await model.delete(id) }
        }
    }
}

// MARK: - Empty and diagnostic states

/// The first screen anyone sees.
///
/// `ContentUnavailableView` rather than a hand-built stack of `Image`/`Text`/`Button`. It is the
/// system's empty state, which means it gets the platform's icon size, its type scale, its spacing
/// and its centring for free — and, more to the point, it keeps getting them when the platform
/// changes its mind, which is precisely what happened between macOS 15 and 26.
private struct EmptyCollectionView: View {
    var model: CollectionModel

    var body: some View {
        ContentUnavailableView {
            Label("No collection open", systemImage: "folder")
        } description: {
            Text(
                "Nib keeps requests as files in a folder you choose, so you can diff and commit them."
            )
        } actions: {
            Button("Open Folder…") {
                Task { await model.promptToOpen() }
            }
            .buttonStyle(.borderedProminent)
            // macOS 26 grew an extra control size and made the existing ones taller. A primary
            // action in an empty state is the canonical place for `.large`, and asking for it by
            // name means the button tracks the system's metrics instead of the previous OS's.
            .controlSize(.large)

            // The migration hook, on the first screen anyone sees. Someone arriving from Postman
            // should not have to find this in a menu -- it is the reason they downloaded the app.
            Text("Coming from Postman? Drop an export anywhere on this window.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let failure = model.loadFailure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }

            recents
        }
        .padding(.horizontal, Metrics.pane)
    }

    @ViewBuilder
    private var recents: some View {
        let urls = CollectionModel.recentCollections()
        if !urls.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(urls, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        Task { await model.open(url) }
                    }
                    .buttonStyle(.link)
                    .help(url.path)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Metrics.row)
        }
    }
}

/// Anything the store skipped or adjusted while loading.
///
/// Shown rather than logged: a request that failed to parse is exactly the thing a user needs to know
/// about, and it is invisible otherwise because the sidebar just looks one row shorter.
///
/// Draws no background of its own — it is hosted inside the sidebar's `safeAreaBar`, which already
/// supplies the material. See `Banner` for the version that stands alone in content flow.
private struct DiagnosticsBanner: View {
    let messages: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(messages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle")
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, Metrics.chip)
    }
}
