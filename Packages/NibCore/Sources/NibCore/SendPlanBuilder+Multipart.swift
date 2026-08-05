import Foundation

/// `multipart/form-data` assembly.
///
/// Split out because it is the only part of the builder that touches the filesystem, and because
/// the boundary rules deserve their own explanation.
extension SendPlanBuilder {

    /// Where spilled multipart bodies go. A subdirectory of `tmp` so a stray file is obviously
    /// ours and obviously disposable.
    static var multipartScratchDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "Nib-multipart", isDirectory: true)
    }

    /// Anything older than this in the scratch directory is from a previous send and can go.
    static let multipartScratchLifetime: TimeInterval = 3600

    static func buildMultipart(
        _ parts: [MultipartPart],
        resolve: (String) -> String
    ) throws -> BuiltBody {
        let active = parts.filter(\.enabled)
        guard !active.isEmpty else { return BuiltBody(body: .none, contentType: nil) }

        let resolved = active.map { part -> ResolvedPart in
            switch part.content {
            case .text(let text):
                ResolvedPart(
                    name: resolve(part.name), contentType: part.contentType.map(resolve),
                    payload: .text(resolve(text)))
            case .file(let path):
                ResolvedPart(
                    name: resolve(part.name), contentType: part.contentType.map(resolve),
                    payload: .file(URL(fileURLWithPath: resolve(path))))
            }
        }

        for case .file(let url) in resolved.map(\.payload)
        where !FileManager.default.fileExists(atPath: url.path) {
            throw BuildError.missingFile(url.path)
        }

        let boundary = self.boundary(for: resolved)
        let contentType = "multipart/form-data; boundary=\(boundary)"

        // All text: assemble in memory, which is both simpler and faster. A form of text fields is
        // kilobytes.
        guard
            resolved.contains(where: {
                guard case .file = $0.payload else { return false }
                return true
            })
        else {
            var data = Data()
            for part in resolved {
                data.append(header(for: part, boundary: boundary))
                if case .text(let text) = part.payload { data.append(Data(text.utf8)) }
                data.append(Data("\r\n".utf8))
            }
            data.append(Data("--\(boundary)--\r\n".utf8))
            return BuiltBody(body: .bytes(data), contentType: contentType)
        }

        return BuiltBody(
            body: .file(try spill(resolved, boundary: boundary)), contentType: contentType)
    }

    // MARK: - Spilling to disk

    /// Assemble to a temp file, copying file parts through a fixed-size buffer.
    ///
    /// The whole point: attaching a 2 GB video must not put 2 GB in the app's footprint. The engine
    /// streams the result from disk, so the peak is one buffer regardless of upload size.
    private static func spill(_ parts: [ResolvedPart], boundary: String) throws -> URL {
        let directory = multipartScratchDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sweepScratchDirectory()

        let destination = directory.appendingPathComponent("\(boundary).body")
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        guard let output = FileHandle(forWritingAtPath: destination.path) else {
            throw BuildError.unsupportedBody("Could not create a temporary file for the upload.")
        }
        defer { try? output.close() }

        for part in parts {
            try output.write(contentsOf: header(for: part, boundary: boundary))

            switch part.payload {
            case .text(let text):
                try output.write(contentsOf: Data(text.utf8))

            case .file(let url):
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
            }

            try output.write(contentsOf: Data("\r\n".utf8))
        }

        try output.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
        return destination
    }

    /// Delete leftovers from previous sends.
    ///
    /// Run on the way in rather than after a send completes, because "after" is the case that does
    /// not happen when the app is force-quit or the request is cancelled. Best-effort by design:
    /// a failure here must never stop someone sending a request.
    private static func sweepScratchDirectory() {
        let directory = multipartScratchDirectory
        let cutoff = Date().addingTimeInterval(-multipartScratchLifetime)

        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []

        for entry in entries {
            let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Parts

    private struct ResolvedPart {
        enum Payload {
            case text(String)
            case file(URL)
        }

        var name: String
        var contentType: String?
        var payload: Payload
    }

    private static func header(for part: ResolvedPart, boundary: String) -> Data {
        var lines = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(escape(part.name))\""

        if case .file(let url) = part.payload {
            lines += "; filename=\"\(escape(url.lastPathComponent))\""
        }
        lines += "\r\n"

        // The server needs a type for a file part to be useful. Guessing from the extension beats
        // sending everything as octet-stream, and an explicit type from the user always wins.
        if let contentType = part.contentType ?? inferredContentType(for: part) {
            lines += "Content-Type: \(contentType)\r\n"
        }

        return Data((lines + "\r\n").utf8)
    }

    private static func inferredContentType(for part: ResolvedPart) -> String? {
        guard case .file(let url) = part.payload else { return nil }
        return commonContentTypes[url.pathExtension.lowercased()] ?? "application/octet-stream"
    }

    /// A deliberately short table. `UniformTypeIdentifiers` would do this properly but pulls in a
    /// framework for a handful of extensions people actually upload from an API client.
    private static let commonContentTypes: [String: String] = [
        "json": "application/json", "xml": "application/xml", "txt": "text/plain",
        "csv": "text/csv", "html": "text/html", "pdf": "application/pdf",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "svg": "image/svg+xml", "heic": "image/heic",
        "zip": "application/zip", "gz": "application/gzip",
        "mp4": "video/mp4", "mov": "video/quicktime", "mp3": "audio/mpeg", "wav": "audio/wav",
    ]

    /// RFC 7578 says a quoted-string, so a quote or newline in a field name has to not escape it.
    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    // MARK: - Boundary

    /// A boundary derived from the content, not from randomness.
    ///
    /// Deterministic on purpose. The rest of the on-disk and on-the-wire behaviour is reproducible
    /// — sending the same request twice produces the same bytes — and a random boundary would be
    /// the one thing that is not, which makes both tests and `Copy as cURL` awkward for no gain.
    ///
    /// Then the safety property that actually matters: the boundary must not occur inside any part.
    /// Text parts are checked directly and the boundary is extended until it is absent. File parts
    /// are not scanned — reading a 2 GB upload twice to check would undo the streaming — but the
    /// hash is 64 bits behind a fixed prefix, so an accidental occurrence in a file is not a
    /// realistic outcome.
    private static func boundary(for parts: [ResolvedPart]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a offset basis

        func mix(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x1000_0000_01b3
            }
        }

        for part in parts {
            mix(part.name)
            mix(part.contentType ?? "")
            switch part.payload {
            case .text(let text): mix(text)
            case .file(let url): mix(url.path)
            }
        }

        var candidate = "NibBoundary" + String(hash, radix: 16)
        let texts = parts.compactMap { part -> String? in
            if case .text(let text) = part.payload { return text }
            return nil
        }
        while texts.contains(where: { $0.contains(candidate) }) {
            candidate += "x"
        }
        return candidate
    }
}
