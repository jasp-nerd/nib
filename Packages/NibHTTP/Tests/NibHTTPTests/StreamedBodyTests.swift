import Foundation
import NibCore
import NibTestSupport
import Testing

@testable import NibHTTP

/// What arrives at the far end of a `.file` body.
///
/// `MultipartTests` proves the bytes we assemble are right. It cannot prove that URLSession sends
/// them — a file body goes out through a completely different path from a `Data` body, and
/// "uploads an empty body with a Content-Length of zero" is a failure that looks identical to a
/// server bug from inside the app.
@Suite("Streamed bodies", .serialized)
struct StreamedBodyTests {

    private func withServer(
        _ handler: @escaping @Sendable (TestHTTPServer.Request) -> TestHTTPServer.Response,
        _ body: (TestHTTPServer) async throws -> Void
    ) async throws {
        let server = try TestHTTPServer(handler: handler)
        try server.start()
        defer { server.stop() }
        try await body(server)
    }

    private func run(_ plan: SendPlan) async -> [SendEvent] {
        // The engine has to be held in a local for the whole loop. Inlining `HTTPEngine().send(…)`
        // lets it be released as soon as `send` returns the stream, and its `deinit` calls
        // `invalidateAndCancel` — so every request comes back instantly as "Cancelled." with the
        // server having seen nothing. Which is at least proof the deinit works.
        let engine = HTTPEngine()
        var events: [SendEvent] = []
        for await event in engine.send(plan) {
            events.append(event)
        }
        return events
    }

    private func withTemporaryFile(
        _ contents: Data,
        named name: String = "upload.bin",
        _ body: (URL) async throws -> Void
    ) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-stream-\(UUID().uuidString)-\(name)")
        try contents.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await body(url)
    }

    @Test("a file body reaches the server byte for byte")
    func fileBodyIsSent() async throws {
        let payload = Data((0..<4096).map { UInt8($0 % 256) })

        try await withTemporaryFile(payload) { file in
            try await withServer({ _ in .json("{}", status: 201) }) { server in
                let plan = SendPlan(
                    method: .post,
                    url: try #require(URL(string: "\(server.baseURL)/upload")),
                    headers: [
                        SendPlan.Header(name: "Content-Type", value: "application/octet-stream")
                    ],
                    body: .file(file))

                _ = await run(plan)

                let request = try #require(server.received.first)
                #expect(request.body == payload)
            }
        }
    }

    /// The whole multipart path, end to end: builder assembles to a temp file, engine streams it,
    /// server receives a well-formed form.
    @Test("a multipart body assembled to disk arrives intact")
    func multipartRoundTrip() async throws {
        let fileContents = Data("the file contents\n".utf8)

        try await withTemporaryFile(fileContents, named: "notes.txt") { file in
            try await withServer({ _ in .json("{}", status: 201) }) { server in
                let output = try SendPlanBuilder.build(
                    HTTPRequestSpec(
                        method: .post,
                        url: "\(server.baseURL)/upload",
                        body: .multipart([
                            MultipartPart(name: "title", content: .text("My notes")),
                            MultipartPart(name: "file", content: .file(path: file.path)),
                        ])),
                    scope: VariableScope())

                // The builder spilled to a temp file; clean it up whatever the assertions do.
                guard case .file(let assembled) = output.plan.body else {
                    Issue.record("expected a spilled multipart body")
                    return
                }
                defer { try? FileManager.default.removeItem(at: assembled) }
                _ = await run(output.plan)

                let request = try #require(server.received.first)
                let wire = String(decoding: request.body, as: UTF8.self)
                let contentType = try #require(
                    request.headers.first { $0.key.lowercased() == "content-type" }?.value)

                #expect(contentType.hasPrefix("multipart/form-data; boundary="))
                #expect(wire.contains("name=\"title\"\r\n\r\nMy notes\r\n"))
                #expect(wire.contains("name=\"file\"; filename=\"\(file.lastPathComponent)\""))
                #expect(wire.contains("the file contents"))

                // Content-Length must describe the assembled file, not the request as authored.
                let length = request.headers.first { $0.key.lowercased() == "content-length" }?
                    .value
                #expect(length == String(request.body.count))
            }
        }
    }

    @Test("an empty file still produces a body rather than being skipped")
    func emptyFileBody() async throws {
        try await withTemporaryFile(Data()) { file in
            try await withServer({ _ in .json("{}") }) { server in
                let plan = SendPlan(
                    method: .post,
                    url: try #require(URL(string: "\(server.baseURL)/upload")),
                    body: .file(file))
                _ = await run(plan)

                let request = try #require(server.received.first)
                #expect(request.body.isEmpty)
                #expect(request.method == "POST")
            }
        }
    }
}
