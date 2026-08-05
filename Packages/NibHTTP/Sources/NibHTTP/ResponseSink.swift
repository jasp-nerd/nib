import Foundation
import NibCore

/// Where response bytes accumulate.
///
/// Small responses stay in memory; anything past `bodyMemoryLimit` spills to a temp file, so a
/// 200 MB download cannot blow the app's memory budget. The switchover is transparent to the
/// caller and happens mid-stream, because `Content-Length` is frequently absent or wrong.
///
/// Not thread-safe by design — it is confined to the session's serial delegate queue.
final class ResponseSink {
    private enum Storage {
        case memory(Data)
        case file(FileHandle, URL)
    }

    private var storage: Storage = .memory(Data())
    private(set) var byteCount: Int64 = 0

    /// Set when we could not open a spill file. The bytes keep accumulating in memory rather
    /// than being dropped — running out of RAM is a better failure than silently truncating a
    /// response and showing the user a body that is missing its tail.
    private(set) var spillFailure: String?

    func append(_ data: Data) {
        byteCount += Int64(data.count)

        switch storage {
        case .memory(var buffer):
            // Drop `storage`'s reference before appending. Binding `var buffer` leaves the enum
            // holding a second reference, so `append` sees refcount 2 and copy-on-write duplicates
            // everything received so far -- on every single 64 KB callback. Reaching the 8 MB spill
            // threshold moved roughly half a gigabyte and doubled peak memory at precisely the
            // moment the spill machinery exists to prevent that.
            storage = .memory(Data())
            buffer.append(data)
            if byteCount > bodyMemoryLimit, spillFailure == nil {
                spill(buffer)
            } else {
                storage = .memory(buffer)
            }

        case .file(let handle, _):
            do {
                try handle.write(contentsOf: data)
            } catch {
                spillFailure = "Failed writing the response to disk: \(error.localizedDescription)"
            }
        }
    }

    private func spill(_ buffered: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-response-\(UUID().uuidString)")
        do {
            try buffered.write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            storage = .file(handle, url)
        } catch {
            spillFailure =
                "Response too large for memory and could not spill to disk: "
                + error.localizedDescription
            storage = .memory(buffered)
        }
    }

    func finish() -> SendEvent.Payload {
        switch storage {
        case .memory(let data):
            return .memory(data)
        case .file(let handle, let url):
            try? handle.close()
            return .file(url, byteCount: byteCount)
        }
    }

    /// Called when a request fails or is cancelled, so a partial spill file is not left behind.
    func discard() {
        if case .file(let handle, let url) = storage {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
        storage = .memory(Data())
        byteCount = 0
    }
}
