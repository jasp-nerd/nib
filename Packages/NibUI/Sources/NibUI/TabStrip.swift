import NibCore
import SwiftUI

/// The tab strip above the request pane.
///
/// Tabs exist because comparing two endpoints is the second thing anyone does with an API client,
/// and without them the answer is "lose your place". Each tab owns a whole `RequestSession` — its
/// own response, its own in-flight task — so a slow request in one tab does not stop you working
/// in another.
struct TabStrip: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.tabs) { tab in
                        TabButton(
                            tab: tab,
                            isActive: tab.id == model.activeTabID,
                            canClose: model.canCloseTab,
                            select: { model.select(tab.id) },
                            close: { model.closeTab(tab.id) }
                        )
                        Divider().frame(height: 16)
                    }
                }
            }

            Button("New tab", systemImage: "plus") { model.newTab() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
                .help("New tab (⌘T)")
        }
        .frame(height: 30)
        .background(.quaternary.opacity(0.25))
    }
}

private struct TabButton: View {
    var tab: RequestSession
    let isActive: Bool
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(tab.spec.method.rawValue)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(title)
                .lineLimit(1)
                .font(.callout)

            // A spinner rather than a dot: "this tab is still going" is the thing you want to know
            // when you switched away from it.
            if tab.state.isSending {
                ProgressView().controlSize(.mini)
            }

            // The close button appears on hover or when active, so a row of tabs is not a row of
            // little crosses.
            if canClose && (isHovered || isActive) {
                Button("Close tab", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.caption2)
            } else {
                Color.clear.frame(width: 10, height: 1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isActive ? AnyShapeStyle(.background) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
        .help(tab.spec.url.isEmpty ? "New request" : tab.spec.url)
    }

    /// The last path component, falling back to the host, falling back to "New request".
    ///
    /// A full URL does not fit and truncates to a row of identical `https://api.exampl…`, which
    /// tells you nothing about which tab is which.
    private var title: String {
        let url = tab.spec.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return "New request" }

        // Parsed loosely: the URL is a template and may not be a valid URL at all yet.
        let withoutQuery = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        let segments = withoutQuery.split(separator: "/").filter { !$0.isEmpty }

        if let last = segments.last, segments.count > 1, !last.contains(":") {
            return String(last)
        }
        return URL(string: url)?.host() ?? withoutQuery
    }
}
