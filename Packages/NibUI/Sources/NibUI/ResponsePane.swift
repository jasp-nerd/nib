import NibCore
import SwiftUI

/// Status, timing, and the response body.
///
/// The body is a SwiftUI `TextEditor` for now. Phase 6 replaces it with an AppKit `NSTextView` on
/// TextKit 2 plus the JSON viewport highlighter — that has to be real AppKit in a real
/// `NSViewController`, because TextKit 2 rendering attributes misbehave inside
/// `NSViewRepresentable`.
public struct ResponsePane: View {
    var session: RequestSession

    @State private var tab: Tab = .body

    private enum Tab: String, CaseIterable, Identifiable {
        case body = "Body"
        case headers = "Headers"
        case timing = "Timing"
        var id: String { rawValue }
    }

    public init(session: RequestSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            content
        }
    }

    // MARK: - Status bar

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 12) {
            switch session.state {
            case .sending(let received, let expected):
                ProgressView().controlSize(.small)
                Text(progressText(received: received, expected: expected))
                    .foregroundStyle(.secondary)

            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)

            case .idle:
                if let response = session.response {
                    statusPill(response)
                    Text(response.durationText).foregroundStyle(.secondary)
                    Text(response.sizeText).foregroundStyle(.secondary)
                    if let proto = response.networkProtocol {
                        Text(proto)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    if !response.hops.isEmpty {
                        Text(
                            "\(response.hops.count) redirect\(response.hops.count == 1 ? "" : "s")"
                        )
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No response yet — press ⌘↩ to send.")
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if let response = session.response {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)

                Button {
                    copyBody(response)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy response body")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func statusPill(_ response: ResponseViewModel) -> some View {
        let colour: Color =
            response.isSuccess
            ? .green
            : response.isRedirect ? .orange : response.isError ? .red : .secondary

        return Text("\(response.status) \(response.statusText)")
            .font(.system(.callout, design: .monospaced).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(colour, in: RoundedRectangle(cornerRadius: 5))
    }

    private func progressText(received: Int64, expected: Int64?) -> String {
        let receivedText = received.formatted(.byteCount(style: .binary))
        guard let expected, expected > 0 else { return "Sending… \(receivedText)" }
        let total = expected.formatted(.byteCount(style: .binary))
        return "Receiving… \(receivedText) of \(total)"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if case .failed(let message) = session.state {
            // A failure gets the whole pane, not a one-line label in the status bar. When a request
            // dies the status-bar version is easy to miss entirely -- it reads as "nothing
            // happened", which is the worst possible feedback for a tool whose only job is to make
            // one request and tell you what came back.
            failureView(message)
        } else if let response = session.response {
            switch tab {
            case .body: bodyView(response)
            case .headers: headersView(response)
            case .timing: TimingWaterfall(timing: response.timing, hops: response.hops)
            }
        } else {
            Spacer()
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("The request failed")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func bodyView(_ response: ResponseViewModel) -> some View {
        VStack(spacing: 0) {
            if response.isTruncated {
                Label(
                    "Showing the first \(Int64(ResponseViewModel.displayLimit).formatted(.byteCount(style: .binary))) of \(response.sizeText).",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.4))
            }
            TextEditor(text: .constant(response.bodyText))
                .font(.system(.body, design: .monospaced))
        }
    }

    private func headersView(_ response: ResponseViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(response.headers.enumerated()), id: \.offset) { _, header in
                    HStack(alignment: .top, spacing: 8) {
                        Text(header.name)
                            .fontWeight(.medium)
                            .frame(width: 220, alignment: .leading)
                        Text(header.value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }

    private func copyBody(_ response: ResponseViewModel) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(response.bodyText, forType: .string)
        #endif
    }
}

// MARK: - Timing

/// A stacked bar of the request phases, from real `URLSessionTaskMetrics`.
///
/// DNS, connect and TLS are legitimately absent on loopback or a reused pooled connection — that is
/// information, not missing data, so those rows are simply not drawn.
struct TimingWaterfall: View {
    let timing: SendEvent.Timing
    let hops: [SendEvent.Hop]

    private var phases: [(String, Duration)] {
        [
            ("DNS", timing.dns),
            ("Connect", timing.connect),
            ("TLS", timing.tls),
            ("Request", timing.request),
            ("Waiting", timing.timeToFirstByte),
            ("Download", timing.download),
        ].compactMap { name, value in value.map { (name, $0) } }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                let total = max(milliseconds(timing.total), 0.001)

                ForEach(phases, id: \.0) { name, duration in
                    let ms = milliseconds(duration)
                    HStack(spacing: 8) {
                        Text(name)
                            .frame(width: 90, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.tint)
                                .frame(width: max(2, geometry.size.width * (ms / total)))
                        }
                        .frame(height: 12)
                        Text(String(format: "%.1f ms", ms))
                            .frame(width: 80, alignment: .leading)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(.callout, design: .monospaced))
                }

                if phases.isEmpty {
                    Text("No phase breakdown: the connection was reused or served from loopback.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }

                Divider()
                HStack(spacing: 8) {
                    Text("Total").frame(width: 90, alignment: .trailing).fontWeight(.semibold)
                    Text(String(format: "%.1f ms", milliseconds(timing.total)))
                }
                .font(.system(.callout, design: .monospaced))

                if !hops.isEmpty {
                    Divider()
                    Text("Redirects").fontWeight(.semibold)
                    ForEach(Array(hops.enumerated()), id: \.offset) { _, hop in
                        Text("\(hop.status)  \(hop.from.absoluteString) → \(hop.to.absoluteString)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(12)
        }
    }
}
