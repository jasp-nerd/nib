// Record a single window to a .mov, and nothing else.
//
// The important part is SCContentFilter(desktopIndependentWindow:): ScreenCaptureKit composites
// that one window on its own, so whatever is behind it — or on top of it — never reaches a frame.
// A screen-region capture cannot promise that, which is how an earlier attempt at this recorded
// an editor full of somebody's files instead of the app.
//
//   record-window <owner> <out.mov> <maxSeconds> <stopFile>

import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

// Building an SCContentFilter needs a window-server connection, which a plain command-line tool
// does not get: without this, ScreenCaptureKit trips the CGS_REQUIRE_INIT assertion and the process
// aborts. Touching NSApplication establishes it. The app is never run, so no run loop is started
// and nothing appears in the Dock.
_ = NSApplication.shared

let arguments = CommandLine.arguments
guard arguments.count == 6,
    let maxSeconds = Double(arguments[4])
else {
    FileHandle.standardError.write(
        Data("usage: record-window <owner> window|app <out.mov> <maxSeconds> <stopFile>\n".utf8))
    exit(2)
}
let owner = arguments[1]
let mode = arguments[2]
let output = URL(fileURLWithPath: arguments[3])
let stopFile = arguments[5]

// MARK: - Sink

/// Holds the writer. A class because SCStreamOutput is a delegate protocol, and the frame callback
/// arrives on ScreenCaptureKit's own queue rather than on main.
final class Sink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private(set) var frameCount = 0

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    // Generous for a screen recording. Text has to stay legible after upload.
                    AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw Failure("the writer rejected the video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure("could not start writing: \(writer.error?.localizedDescription ?? "?")")
        }
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(buffer) else { return }

        // ScreenCaptureKit sends a frame on a fixed cadence whether or not anything changed, and
        // marks the unchanged ones .idle. Writing those is harmless but pointless; what must be
        // skipped is .blank, which carries no surface at all.
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw),
            status == .complete || status == .idle,
            let pixels = CMSampleBufferGetImageBuffer(buffer)
        else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        if !started {
            writer.startSession(atSourceTime: time)
            started = true
        }
        // Never block this callback.
        //
        // An earlier version waited here for the encoder to catch up. It fixed the dropped-tail
        // problem and broke something much worse: stalling ScreenCaptureKit's delivery queue made
        // the captured app miss mouse clicks, so takes came out with the pointer sitting on a tab
        // that never got selected. Skip the frame instead, and keep a copy so the tail can still be
        // recovered -- see `flushPending`.
        guard input.isReadyForMoreMediaData else {
            remember(pixels, at: time)
            return
        }
        if adaptor.append(pixels, withPresentationTime: time) {
            frameCount += 1
            pendingTime = nil
        } else {
            complain(
                "append failed, writer status \(writer.status.rawValue): "
                    + (writer.error?.localizedDescription ?? "no error"))
            remember(pixels, at: time)
        }
    }

    // MARK: - The tail
    //
    // ScreenCaptureKit only emits a frame when something changes, so a skipped frame is not "one
    // frame of a smooth 30fps" -- it can be the only record of a state the screen then holds still
    // for seconds. Skipping the repaint after a click, with nothing moving afterwards, ends the
    // clip on the previous state. So the most recent skipped frame is copied out of the stream's
    // pool and appended once at the end.

    private var pendingBuffer: CVPixelBuffer?
    private var pendingTime: CMTime?

    private func remember(_ pixels: CVPixelBuffer, at time: CMTime) {
        guard let copy = Self.copy(pixels) else { return }
        pendingBuffer = copy
        pendingTime = time
    }

    /// A deep copy: the source belongs to the stream's pool and is recycled the moment we return.
    private static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var destination: CVPixelBuffer?
        let attributes =
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary] as CFDictionary
        guard
            CVPixelBufferCreate(
                nil, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
                CVPixelBufferGetPixelFormatType(source), attributes, &destination)
                == kCVReturnSuccess,
            let destination
        else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard
            let from = CVPixelBufferGetBaseAddress(source),
            let to = CVPixelBufferGetBaseAddress(destination)
        else { return nil }

        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let destinationStride = CVPixelBufferGetBytesPerRow(destination)
        let height = CVPixelBufferGetHeight(source)
        if sourceStride == destinationStride {
            memcpy(to, from, sourceStride * height)
        } else {
            let width = min(sourceStride, destinationStride)
            for row in 0..<height {
                memcpy(to + row * destinationStride, from + row * sourceStride, width)
            }
        }
        return destination
    }

    /// Append the last skipped frame. Called after the stream has stopped, so waiting for the
    /// encoder here costs nothing and stalls nothing.
    private func flushPending() {
        lock.lock()
        let buffer = pendingBuffer
        let time = pendingTime
        pendingBuffer = nil
        pendingTime = nil
        lock.unlock()

        guard let buffer, let time else { return }
        var waited = 0
        while !input.isReadyForMoreMediaData && waited < 400 {
            usleep(5_000)
            waited += 1
        }
        guard input.isReadyForMoreMediaData else { return }
        if adaptor.append(buffer, withPresentationTime: time) { frameCount += 1 }
    }

    /// Once, not per frame — a broken writer would otherwise print thousands of lines.
    private var complained = false
    private func complain(_ message: String) {
        guard !complained else { return }
        complained = true
        FileHandle.standardError.write(Data("record-window: \(message)\n".utf8))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("stream stopped: \(error.localizedDescription)\n".utf8))
    }

    /// Separate from `finish()` because taking a lock inside an async function is an error in the
    /// Swift 6 language mode: there is no guarantee the same thread resumes after a suspension.
    /// Nothing suspends between these two lines, so doing it synchronously is both correct and
    /// provably so.
    private func claimFinish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard started, !finished else { return false }
        finished = true
        return true
    }

    func finish() async {
        flushPending()
        guard claimFinish() else { return }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            FileHandle.standardError.write(
                Data("write failed: \(writer.error?.localizedDescription ?? "?")\n".utf8))
        }
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Run

func run() async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
        true, onScreenWindowsOnly: true)

    let filter: SCContentFilter
    switch mode {
    case "window":
        // The app owns several windows besides the one worth filming: a wide, short menu-bar window
        // and a couple of small panels, and they sort ahead of the real one. Largest area wins,
        // rather than a hardcoded size threshold — the main window is whatever size the user left
        // it, so any threshold is a guess that eventually picks nothing.
        guard
            let window = content.windows
                .filter({ $0.owningApplication?.applicationName == owner })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
            window.frame.width > 600, window.frame.height > 400
        else {
            throw Failure("no window worth recording owned by \(owner)")
        }
        filter = SCContentFilter(desktopIndependentWindow: window)

    case "app":
        // Everything the app owns, over the desktop, with every other application omitted. Needed
        // because the import panel is `runModal()` — a separate window rather than a sheet — so a
        // window-scoped capture would show the app apparently freezing while the user picks a file.
        //
        // This still cannot leak: filtering by application is done by the compositor, so another
        // app's window overlapping Nib is not rendered at all rather than being cropped out.
        guard let application = content.applications.first(where: { $0.applicationName == owner })
        else { throw Failure("\(owner) is not running") }
        guard let display = content.displays.first else { throw Failure("no display") }
        filter = SCContentFilter(
            display: display, including: [application], exceptingWindows: [])

    default:
        throw Failure("mode must be 'window' or 'app'")
    }
    let scale = filter.pointPixelScale
    // h264 wants even dimensions.
    let width = Int((filter.contentRect.width * CGFloat(scale)).rounded()) & ~1
    let height = Int((filter.contentRect.height * CGFloat(scale)).rounded()) & ~1

    let sink = try Sink(url: output, width: width, height: height)

    let configuration = SCStreamConfiguration()
    configuration.width = width
    configuration.height = height
    // 30, not 60. At 3024x1964 the h264 encoder cannot keep up with 60, so `isReadyForMoreMediaData`
    // goes false and frames are dropped -- and because the drops cluster at the end, clips were
    // losing their last second or two. That is how a take came out with a tab click that had
    // plainly happened, and a recording that stopped just before it took effect. Nothing on screen
    // here moves fast enough for 60 to buy anything.
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = true
    configuration.capturesAudio = false
    configuration.scalesToFit = false
    configuration.queueDepth = 8

    let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
    try stream.addStreamOutput(
        sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "app.nib.record"))
    try await stream.startCapture()

    print("recording \(mode) \(width)x\(height)")
    FileManager.default.createFile(atPath: "/tmp/nib-record.ready", contents: nil)

    let deadline = Date().addingTimeInterval(maxSeconds)
    while Date() < deadline, !FileManager.default.fileExists(atPath: stopFile) {
        try await Task.sleep(for: .milliseconds(100))
    }

    try? await stream.stopCapture()
    await sink.finish()
    try? FileManager.default.removeItem(atPath: "/tmp/nib-record.ready")
    print("wrote \(sink.frameCount) frames to \(output.path)")
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("record-window: \(error)\n".utf8))
    exit(1)
}
