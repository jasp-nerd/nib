import SwiftUI

/// The sidebar, until Phase 3 gives it a collection tree to show.
///
/// Kept as a real pane rather than an empty view so the window has its final three-pane shape and
/// the launch measurement includes the actual cost of standing up SwiftUI hosting.
public struct SidebarPlaceholder: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No collection open")
                .font(.headline)
            Text(
                "Opening a folder and importing from Postman arrive in Phase 3 and Phase 4. "
                    + "Until then, the request above is scratch space."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
