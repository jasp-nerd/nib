import Foundation
import Testing

@testable import NibCore

@Suite("Multipart bodies")
struct MultipartTests {

    private func build(
        _ parts: [MultipartPart],
        scope: VariableScope = VariableScope()
    ) throws -> (body: SendPlan.Body, contentType: String) {
        let output = try SendPlanBuilder.build(
            HTTPRequestSpec(
                method: .post, url: "https://api.example.com/upload",
                body: .multipart(parts)),
            scope: scope)
        let contentType = try #require(
            output.plan.headers.first {
                $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
            }
        ).value
        return (output.plan.body, contentType)
    }

    private func text(of body: SendPlan.Body) throws -> String {
        switch body {
        case .bytes(let data):
            return String(decoding: data, as: UTF8.self)
        case .file(let url):
            return String(decoding: try Data(contentsOf: url), as: UTF8.self)
        case .none:
            return ""
        }
    }

    private func boundary(in contentType: String) throws -> String {
        let marker = "boundary="
        let index = try #require(contentType.range(of: marker))
        return String(contentType[index.upperBound...])
    }

    // MARK: - Text parts

    @Test("text parts assemble in memory with CRLF separators")
    func textParts() throws {
        let (body, contentType) = try build([
            MultipartPart(name: "title", content: .text("Hello")),
            MultipartPart(name: "count", content: .text("2")),
        ])

        guard case .bytes = body else {
            Issue.record("a form of text fields should not touch the disk")
            return
        }

        let boundary = try boundary(in: contentType)
        let wire = try text(of: body)

        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        #expect(wire.hasPrefix("--\(boundary)\r\n"))
        #expect(wire.hasSuffix("--\(boundary)--\r\n"))
        #expect(wire.contains("Content-Disposition: form-data; name=\"title\"\r\n\r\nHello\r\n"))
        #expect(wire.contains("Content-Disposition: form-data; name=\"count\"\r\n\r\n2\r\n"))

        // Every line break in the framing must be CRLF. A lone LF makes some servers read the
        // header block as part of the value.
        #expect(!wire.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test("a disabled part is not sent, and its absence changes nothing else")
    func disabledPart() throws {
        let (body, _) = try build([
            MultipartPart(name: "keep", content: .text("yes")),
            MultipartPart(name: "drop", content: .text("no"), enabled: false),
        ])
        let wire = try text(of: body)
        #expect(wire.contains("name=\"keep\""))
        #expect(!wire.contains("name=\"drop\""))
    }

    @Test("an all-disabled body sends nothing at all")
    func allDisabled() throws {
        let output = try SendPlanBuilder.build(
            HTTPRequestSpec(
                method: .post, url: "https://api.example.com/upload",
                body: .multipart([
                    MultipartPart(name: "a", content: .text("1"), enabled: false)
                ])),
            scope: VariableScope())
        #expect(output.plan.body == SendPlan.Body.none)
        #expect(!output.plan.headers.contains { $0.name == "Content-Type" })
    }

    @Test("variables are resolved in names, values and content types")
    func variablesResolved() throws {
        let scope = VariableScope.environment(["who": "ada", "kind": "text/markdown"])
        let (body, _) = try build(
            [
                MultipartPart(
                    name: "{{who}}", content: .text("hi {{who}}"), contentType: "{{kind}}")
            ],
            scope: scope)

        let wire = try text(of: body)
        #expect(wire.contains("name=\"ada\""))
        #expect(wire.contains("Content-Type: text/markdown"))
        #expect(wire.contains("hi ada"))
    }

    /// RFC 7578 uses a quoted-string, so a quote in a field name must not end it early.
    @Test("a quote in a field name is escaped rather than closing the quoted string")
    func escapedName() throws {
        let (body, _) = try build([
            MultipartPart(name: #"od"d"#, content: .text("x"))
        ])
        #expect(try text(of: body).contains(#"name="od\"d""#))
    }

    // MARK: - File parts

    private func withTemporaryFile(
        named name: String,
        contents: Data,
        _ body: (URL) throws -> Void
    ) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-multipart-\(UUID().uuidString)-\(name)")
        try contents.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    /// A file part must not be read into memory, so the assembled body goes to disk and the engine
    /// streams it. Attaching a large file must not show up in the app's footprint.
    @Test("a file part spills the assembled body to disk rather than building it in memory")
    func filePartSpills() throws {
        try withTemporaryFile(named: "notes.txt", contents: Data("file contents".utf8)) { url in
            let (body, contentType) = try build([
                MultipartPart(name: "field", content: .text("value")),
                MultipartPart(name: "upload", content: .file(path: url.path)),
            ])

            guard case .file(let assembled) = body else {
                Issue.record("expected the body to be spilled to a file")
                return
            }
            defer { try? FileManager.default.removeItem(at: assembled) }

            let wire = try text(of: body)
            let boundary = try boundary(in: contentType)

            #expect(wire.contains("name=\"upload\"; filename=\"\(url.lastPathComponent)\""))
            #expect(wire.contains("Content-Type: text/plain"))
            #expect(wire.contains("file contents"))
            #expect(wire.contains("name=\"field\"\r\n\r\nvalue\r\n"))
            #expect(wire.hasSuffix("--\(boundary)--\r\n"))
        }
    }

    @Test("the content type is guessed from the extension and an explicit one wins")
    func contentTypeInference() throws {
        try withTemporaryFile(named: "avatar.png", contents: Data([0x89, 0x50, 0x4E, 0x47])) {
            url in
            let (guessed, _) = try build([
                MultipartPart(name: "image", content: .file(path: url.path))
            ])
            #expect(try text(of: guessed).contains("Content-Type: image/png"))
            if case .file(let assembled) = guessed {
                try? FileManager.default.removeItem(at: assembled)
            }

            let (explicit, _) = try build([
                MultipartPart(
                    name: "image", content: .file(path: url.path),
                    contentType: "application/x-custom")
            ])
            #expect(try text(of: explicit).contains("Content-Type: application/x-custom"))
            if case .file(let assembled) = explicit {
                try? FileManager.default.removeItem(at: assembled)
            }
        }
    }

    /// Binary content must survive byte for byte. A round trip through `String` would corrupt it,
    /// which is exactly what streaming through a `FileHandle` avoids.
    @Test("binary file contents are copied byte for byte")
    func binaryFidelity() throws {
        let bytes = Data((0...255).map { UInt8($0) })
        try withTemporaryFile(named: "blob.bin", contents: bytes) { url in
            let (body, _) = try build([
                MultipartPart(name: "blob", content: .file(path: url.path))
            ])
            guard case .file(let assembled) = body else {
                Issue.record("expected a spilled body")
                return
            }
            defer { try? FileManager.default.removeItem(at: assembled) }

            let written = try Data(contentsOf: assembled)
            #expect(written.range(of: bytes) != nil)
        }
    }

    @Test("a missing file is a clear error, not a silently empty part")
    func missingFile() {
        #expect(throws: SendPlanBuilder.BuildError.missingFile("/no/such/file.txt")) {
            _ = try build([
                MultipartPart(name: "upload", content: .file(path: "/no/such/file.txt"))
            ])
        }
    }

    // MARK: - The boundary

    @Test("the same parts produce the same boundary twice")
    func deterministicBoundary() throws {
        let parts = [MultipartPart(name: "a", content: .text("1"))]
        let first = try build(parts).contentType
        let second = try build(parts).contentType
        #expect(first == second)
    }

    @Test("different parts produce different boundaries")
    func boundaryVariesWithContent() throws {
        let first = try build([MultipartPart(name: "a", content: .text("1"))]).contentType
        let second = try build([MultipartPart(name: "a", content: .text("2"))]).contentType
        #expect(first != second)
    }

    /// The one property a boundary must have. If a part contains it, the server truncates the
    /// upload at that point and the failure looks like data corruption rather than a framing bug.
    @Test("the boundary is extended until it does not occur inside any text part")
    func boundaryAvoidsCollision() throws {
        // Build once to learn the boundary this content would produce...
        let probe = try build([MultipartPart(name: "a", content: .text("x"))]).contentType
        let colliding = try boundary(in: probe)

        // ...then put that exact string inside the part and rebuild.
        let (body, contentType) = try build([
            MultipartPart(name: "a", content: .text("prefix \(colliding) suffix"))
        ])
        let chosen = try boundary(in: contentType)
        let wire = try text(of: body)

        #expect(chosen != colliding)
        #expect(wire.contains("prefix \(colliding) suffix"))
        // Exactly two framing occurrences: the opening delimiter and the closing one.
        #expect(wire.components(separatedBy: "--\(chosen)").count == 3)
    }
}
