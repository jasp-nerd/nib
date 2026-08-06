import NibInterchange
import SwiftUI

/// What the import did, and what it could not do.
///
/// This sheet is the honest half of the migration hook. "Import everything from Postman" is only
/// trustworthy if the one thing Nib cannot do — run scripts — is stated plainly at the moment of
/// import, naming the exact requests, rather than discovered later when a request returns 401.
public struct ImportReportSheet: View {
    let report: ImportCoordinator.Report
    var onDismiss: () -> Void

    public init(report: ImportCoordinator.Report, onDismiss: @escaping () -> Void) {
        self.report = report
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if report.isClean {
                clean
            } else {
                diagnostics
            }

            Divider()
            footer
        }
        .frame(width: 620, height: report.isClean ? 260 : 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Imported \(report.requestCount) request\(report.requestCount == 1 ? "" : "s")",
                systemImage: "checkmark.circle.fill"
            )
            .font(.headline)
            .foregroundStyle(.green)

            if !report.collectionNames.isEmpty {
                Text(report.collectionNames.joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !report.environmentNames.isEmpty {
                Text(
                    "Environments: \(report.environmentNames.joined(separator: ", "))"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    /// `ContentUnavailableView` is right here and wrong in the sidebar, and the difference is
    /// simply that this sheet is 620pt wide. It is the system's "nothing further to show" layout,
    /// and this is a 620x260 panel with one message in the middle of it — exactly its shape.
    private var clean: some View {
        ContentUnavailableView {
            Label("Everything came across", systemImage: "sparkles")
                .symbolRenderingMode(.hierarchical)
        } description: {
            Text("Your requests are files in your collection folder — commit them.")
        }
    }

    /// Grouped by severity, with the ones that change behaviour first.
    private var diagnostics: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                group(
                    .preserved,
                    title: "Kept, but Nib will not run it",
                    explanation:
                        "These were imported and are stored in your files. They round-trip untouched, "
                        + "so nothing is lost — Nib just does not execute them."
                )
                group(
                    .adjusted,
                    title: "Imported with a change",
                    explanation: "These work, with the difference noted."
                )
                group(
                    .dropped,
                    title: "Could not be imported",
                    explanation: "These could not be represented at all."
                )
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func group(
        _ severity: ImportDiagnostic.Severity,
        title: String,
        explanation: String
    ) -> some View {
        let items = report.diagnostics.filter { $0.severity == severity }

        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "\(title) (\(items.count))",
                    systemImage: Self.icon(for: severity)
                )
                .font(.headline)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Self.colour(for: severity))

                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 1) {
                        // Naming the exact request is the point. "Some requests have scripts" is not
                        // actionable; "Users / Create user" is.
                        Text(item.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(item.message)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.row)
                    .background(.quaternary.opacity(0.35), in: ConcentricRectangle())
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Scripts may come later. An account never will.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Done", action: onDismiss)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private static func icon(for severity: ImportDiagnostic.Severity) -> String {
        switch severity {
        case .preserved: "archivebox"
        case .adjusted: "info.circle"
        case .dropped: "exclamationmark.triangle"
        }
    }

    private static func colour(for severity: ImportDiagnostic.Severity) -> Color {
        switch severity {
        case .preserved: .blue
        case .adjusted: .secondary
        case .dropped: .orange
        }
    }
}

// MARK: - Drag and drop

/// Accepts a dropped Postman export anywhere on the window.
///
/// Drag-and-drop is the gesture the launch video shows, so it needs to work on the whole window rather
/// than a small target the user has to aim at.
struct ImportDropTarget: ViewModifier {
    var coordinator: ImportCoordinator
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    // `ConcentricRectangle`, not `RoundedRectangle(cornerRadius: 8)`. This border
                    // is drawn over the whole window, and macOS 26 made window corners noticeably
                    // rounder — an 8pt box against a rounder window cuts across its corners, which
                    // is the single most obvious "built for the last OS" tell there is. Concentric
                    // corners derive their radius from the container, so the highlight follows the
                    // window whatever the system decides that radius is.
                    ConcentricRectangle()
                        .fill(.tint.opacity(0.06))
                        // Stroked at double width and clipped back to the shape, rather than
                        // `strokeBorder`: `ConcentricRectangle` is a `Shape` but not an
                        // `InsettableShape`, so it cannot inset its own path. A plain `stroke`
                        // straddles the edge and loses half its width off the window.
                        .overlay {
                            ConcentricRectangle().stroke(.tint, lineWidth: 6)
                        }
                        .clipShape(ConcentricRectangle())
                        .allowsHitTesting(false)
                        .overlay {
                            Label("Drop to import", systemImage: "square.and.arrow.down")
                                .font(.headline)
                                .padding(Metrics.pane)
                                .background(.regularMaterial, in: .capsule)
                        }
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.15), value: isTargeted)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                Task { await handle(providers) }
                return true
            }
    }

    private func handle(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        var rejected: [String] = []

        for provider in providers {
            guard let url = await Self.loadURL(from: provider) else { continue }
            if ImportCoordinator.canImport(url) {
                urls.append(url)
            } else {
                rejected.append(url.lastPathComponent)
            }
        }

        // Say so. This used to return silently, which meant the window lit up with "Drop to import",
        // accepted the drop, and then did absolutely nothing — on the one gesture the empty state
        // tells every new user to perform. A drop that cannot work has to explain itself.
        guard !urls.isEmpty else {
            coordinator.reportUnsupportedDrop(rejected)
            return
        }
        await coordinator.importFiles(urls)
    }

    /// `loadItem` is callback-based, so bridge it once here rather than at each call site.
    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}

extension View {
    func importDropTarget(_ coordinator: ImportCoordinator) -> some View {
        modifier(ImportDropTarget(coordinator: coordinator))
    }
}
