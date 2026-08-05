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
        VStack(spacing: 0) {
            filterField

            if !model.diagnostics.isEmpty {
                DiagnosticsBanner(messages: model.diagnostics)
            }

            List(selection: Binding($model.selectedRequestID)) {
                Section(collection.name) {
                    ForEach(filtered(collection.children), id: \.id) { node in
                        NodeRow(node: node, model: model)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            footer
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $filter)
                .textFieldStyle(.plain)
            if !filter.isEmpty {
                Button("Clear filter", systemImage: "xmark.circle.fill") { filter = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack(spacing: 4) {
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
                }
                .buttonStyle(.plain)
                .help("Reveal \(root.path) in Finder")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
                .foregroundStyle(Self.colour(for: request.spec.method))
                .frame(width: 38, alignment: .leading)
            Text(request.name)
                .lineLimit(1)
        }
        .tag(request.id)
        .contextMenu { NodeMenu(id: request.id, model: model) }
    }

    /// Method colours follow the convention every API client uses, so the sidebar is scannable
    /// without reading the text.
    private static func colour(for method: HTTPMethod) -> Color {
        switch method {
        case .get: .blue
        case .post: .green
        case .put, .patch: .orange
        case .delete: .red
        default: .secondary
        }
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

private struct EmptyCollectionView: View {
    var model: CollectionModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("No collection open")
                .font(.headline)
            Text(
                "Nib keeps requests as files in a folder you choose, so you can diff and commit them."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button("Open Folder…") {
                Task { await model.promptToOpen() }
            }
            .buttonStyle(.borderedProminent)

            if let failure = model.loadFailure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }

            let recents = CollectionModel.recentCollections()
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(recents, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            Task { await model.open(url) }
                        }
                        .buttonStyle(.link)
                        .help(url.path)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(18)
    }
}

/// Anything the store skipped or adjusted while loading.
///
/// Shown rather than logged: a request that failed to parse is exactly the thing a user needs to know
/// about, and it is invisible otherwise because the sidebar just looks one row shorter.
private struct DiagnosticsBanner: View {
    let messages: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(messages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
    }
}
