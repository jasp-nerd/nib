import NibCore
import SwiftUI

/// The editable key/value grid, used for headers, query and path parameters, form fields, and
/// multipart text parts.
///
/// One implementation rather than four. `AGENTS.md` puts it plainly — if you find yourself writing
/// a third slightly-different version of something, stop and reuse the first — and a key/value
/// table is the single most duplicated widget in every API client. The Postman behaviours everyone
/// expects live here once: a permanently blank trailing row that materialises when typed into, a
/// per-row checkbox that keeps the value when unticked, and deletion that survives a focused field
/// holding a stale index.
///
/// Generic over the element with key paths rather than a protocol. `HeaderField`, `Param` and
/// `MultipartPart` are on-disk model types that have no business gaining a UI protocol conformance,
/// and the key paths say exactly as much as a protocol would.
struct KeyValueTable<Element, Accessory: View>: View {
    @Binding var rows: [Element]

    let keyPath: WritableKeyPath<Element, String>
    let valuePath: WritableKeyPath<Element, String>
    let enabledPath: WritableKeyPath<Element, Bool>
    let makeRow: (String) -> Element

    var keyPlaceholder = "Key"
    var valuePlaceholder = "Value"
    /// Drawn between the value field and the remove button. Used for the query/path picker.
    @ViewBuilder var accessory: (Binding<Element>) -> Accessory

    /// Real `@State`, not a binding whose getter always returns "".
    ///
    /// That trick drove the field back to empty after each committed keystroke, so typing "abc"
    /// produced either three one-character rows or one row plus stray text, depending on when
    /// AppKit re-read the getter.
    @State private var draftKey = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Positional identity. These are pure value types with no id — see `HeaderField`'s
                // doc comment for why adding one was tried and rejected — so a delete does shift
                // identity. The deferred removal below is what keeps that from committing an edit
                // through a stale index.
                ForEach(rows.indices, id: \.self) { index in
                    row(at: index)
                    Divider()
                }
                blankRow
            }
        }
    }

    private func row(at index: Int) -> some View {
        HStack(spacing: 8) {
            Toggle("Include this row", isOn: binding(index, enabledPath))
                .labelsHidden()
                .help("Include this row")

            TextField(keyPlaceholder, text: binding(index, keyPath))
            TextField(valuePlaceholder, text: binding(index, valuePath))

            accessory($rows[index])

            Button("Remove row", systemImage: "minus.circle") { remove(at: index) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove")
        }
        .font(.system(.body, design: .monospaced))
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .opacity(rows[index][keyPath: enabledPath] ? 1 : 0.5)
    }

    /// Typing anything here materialises a real row, so adding one never needs a button.
    private var blankRow: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: .constant(false)).labelsHidden().disabled(true)
            TextField(keyPlaceholder, text: $draftKey)
                .onChange(of: draftKey) {
                    guard !draftKey.isEmpty else { return }
                    rows.append(makeRow(draftKey))
                    draftKey = ""
                }
            Spacer()
            // A fixed-width spacer rather than a hidden image: an invisible-but-hittable control is
            // a VoiceOver artefact.
            Color.clear.frame(width: 20, height: 1)
        }
        .font(.system(.body, design: .monospaced))
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Remove on the next runloop pass rather than during the current view update.
    ///
    /// Mutating the array while a focused `TextField` in a later row still holds a binding to its
    /// old index is the shape that commits an edit through a stale index — out of bounds if the row
    /// was the last one. Deferring lets the field give up focus first.
    private func remove(at index: Int) {
        DispatchQueue.main.async {
            guard rows.indices.contains(index) else { return }
            rows.remove(at: index)
        }
    }

    /// Bounds-checked in both directions, because a row can disappear between a redraw being
    /// scheduled and the binding being read.
    private func binding<Value>(
        _ index: Int,
        _ path: WritableKeyPath<Element, Value>
    ) -> Binding<Value> where Value: Equatable {
        Binding(
            get: { rows.indices.contains(index) ? rows[index][keyPath: path] : placeholder(path) },
            set: {
                guard rows.indices.contains(index) else { return }
                rows[index][keyPath: path] = $0
            }
        )
    }

    /// A value to show for a row that has just vanished. Never written back.
    private func placeholder<Value>(_ path: WritableKeyPath<Element, Value>) -> Value {
        // Reachable only in the one-frame window described above, where the row is already gone
        // and whatever is returned is discarded on the next pass.
        if let empty = "" as? Value { return empty }
        if let flag = false as? Value { return flag }
        preconditionFailure("KeyValueTable supports String and Bool columns")
    }
}

extension KeyValueTable where Accessory == EmptyView {
    init(
        rows: Binding<[Element]>,
        keyPath: WritableKeyPath<Element, String>,
        valuePath: WritableKeyPath<Element, String>,
        enabledPath: WritableKeyPath<Element, Bool>,
        keyPlaceholder: String = "Key",
        valuePlaceholder: String = "Value",
        makeRow: @escaping (String) -> Element
    ) {
        self.init(
            rows: rows,
            keyPath: keyPath,
            valuePath: valuePath,
            enabledPath: enabledPath,
            makeRow: makeRow,
            keyPlaceholder: keyPlaceholder,
            valuePlaceholder: valuePlaceholder,
            accessory: { _ in EmptyView() }
        )
    }
}
