import NibCore
import SwiftUI

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
                    PhaseBar(
                        name: name,
                        milliseconds: milliseconds(duration),
                        fraction: milliseconds(duration) / total)
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
                    Text("Redirect chain").fontWeight(.semibold)
                    RedirectChain(hops: hops)
                }
            }
            .padding(12)
        }
    }
}

/// Every hop the request took before it landed.
///
/// Worth drawing properly rather than listing as text: a redirect chain is where an unexpected
/// http-to-https bounce, a lost Authorization header, or a POST silently becoming a GET shows up,
/// and each of those is invisible if the chain is a grey one-liner.
private struct RedirectChain: View {
    let hops: [SendEvent.Hop]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(hops.enumerated()), id: \.offset) { index, hop in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, alignment: .trailing)

                    Text("\(hop.status)")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange, in: RoundedRectangle(cornerRadius: 4))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(hop.from.absoluteString)
                            .foregroundStyle(.secondary)
                        Text("→ \(hop.to.absoluteString)")
                        if hop.from.scheme == "http", hop.to.scheme == "https" {
                            Text(
                                "Upgraded to https. The first request went over the network "
                                    + "unencrypted, headers included."
                            )
                            .foregroundStyle(.orange)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)

                    Spacer(minLength: 0)

                    Button("Copy this URL", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hop.to.absoluteString, forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy \(hop.to.absoluteString)")
                }
            }
        }
    }
}

/// One phase row.
///
/// Uses a proportional frame rather than a `GeometryReader` per row. A `GeometryReader` in a stack
/// row forces a layout pass to read its own size and then a second one to place the child, six
/// times over — for a bar whose width is a fraction of the container, `containerRelativeFrame`
/// says the same thing in one pass.
private struct PhaseBar: View {
    let name: String
    let milliseconds: Double
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .frame(width: 90, alignment: .trailing)
                .foregroundStyle(.secondary)

            RoundedRectangle(cornerRadius: 3)
                .fill(.tint)
                .frame(height: 12)
                .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
                    max(2, width * 0.6 * fraction)
                }

            Spacer(minLength: 0)

            Text(String(format: "%.1f ms", milliseconds))
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)
        }
        .font(.system(.callout, design: .monospaced))
    }
}
