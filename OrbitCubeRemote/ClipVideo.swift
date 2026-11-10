import AVFoundation
import CoreTransferable
import Network
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private final class ClipMovie: Transferable {
    let url: URL

    init(copying source: URL) throws {
        let extensionName = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(extensionName)
        try FileManager.default.copyItem(at: source, to: destination)
        url = destination
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try ClipMovie(copying: $0.file) }
    }
}

struct ClipVideoPicker: View {
    let parked: Bool
    @State private var selection: PhotosPickerItem?
    @State private var movie: ClipMovie?
    @State private var showingFiles = false
    @State private var loading = false
    @State private var transfer: Task<Void, Never>?
    @State private var message = "Choose a video from Photos or Files."

    var body: some View {
        Group {
            PhotosPicker(selection: $selection, matching: .videos) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }
            .disabled(transfer != nil || loading)
            Button("Choose from Files") { showingFiles = true }
                .disabled(transfer != nil || loading)
            if let movie, transfer == nil {
                Button("Play on Display") { play(movie) }
                    .disabled(!parked || loading)
            }
            if transfer != nil {
                Button("Stop Playback") { transfer?.cancel() }
            }
            Text(message).font(.footnote).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.movie]) { result in
            do {
                let source = try result.get()
                let accessed = source.startAccessingSecurityScopedResource()
                defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                movie = try ClipMovie(copying: source)
                message = "Video ready. Tap Play on Display."
            } catch {
                message = "Could not open the video. \(error.localizedDescription)"
            }
        }
        .task(id: selection) {
            guard let selection else { return }
            loading = true
            defer { loading = false }
            movie = nil
            message = "Loading video from Photos…"
            do {
                let imported = try await selection.loadTransferable(type: ClipMovie.self)
                try Task.checkCancellation()
                movie = imported
                message = imported == nil ? "Photos could not provide this video." : "Video ready. Tap Play on Display."
            } catch {
                if !Task.isCancelled { message = "Could not load the video. \(error.localizedDescription)" }
            }
        }
        .onChange(of: parked) { if !$0 { transfer?.cancel() } }
        .onDisappear { transfer?.cancel() }
    }

    private func play(_ movie: ClipMovie) {
        message = "Connecting to the display…"
        transfer = Task { @MainActor in
            defer { transfer = nil }
            do {
                try await ClipStream.play(movie.url) {
                    message = "Playing on the display. Keep this app open."
                }
                message = "Playback finished."
            } catch {
                message = Task.isCancelled ? "Playback stopped." : error.localizedDescription
            }
        }
    }
}

private enum ClipStream {
    private static let side = 80

    @MainActor
    static func play(_ url: URL, onFirstFrame: () -> Void) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ClipError.message("This file has no playable video.") }
        let images = AVAssetImageGenerator(asset: asset)
        images.appliesPreferredTrackTransform = true
        images.maximumSize = CGSize(width: 320, height: 320)
        images.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        images.requestedTimeToleranceAfter = .zero

        let interval = 0.16
        var position = 0.0
        var first = true
        while position < duration {
            try Task.checkCancellation()
            let start = DispatchTime.now().uptimeNanoseconds
            let frame = try await images.image(at: CMTime(seconds: position, preferredTimescale: 600)).image
            let bytes = try frameBytes(frame)
            let reply: DisplayReply
            do {
                // The first frame waits longer so the Local Network prompt can be answered.
                reply = try await DisplayRequest(path: "/frame", body: bytes, timeout: first ? 20 : 6).run()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ClipError {
                throw error
            } catch {
                throw ClipError.message("Cannot reach the display over Wi-Fi (\(error.localizedDescription)). Stay on its Clip Wi-Fi and allow Local Network for Orbit Cube in iPhone Settings.")
            }
            guard reply.status == 200 else {
                if reply.status == 409 { throw ClipError.message(reply.detail) }
                if reply.status == 403 { throw ClipError.message("Join the Clip Wi-Fi shown on your display.") }
                throw ClipError.message("The display rejected the frame (HTTP \(reply.status)). \(reply.detail)")
            }
            if first {
                first = false
                onFirstFrame()
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            if elapsed < interval {
                try await Task.sleep(nanoseconds: UInt64((interval - elapsed) * 1_000_000_000))
            }
            position += max(interval, elapsed)
        }
    }

    private static func frameBytes(_ image: CGImage) throws -> Data {
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = rgba.withUnsafeMutableBytes { pixels -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: pixels.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            let scale = CGFloat(side) / CGFloat(min(image.width, image.height))
            let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
            context.draw(image, in: CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2,
                                           width: width, height: height))
            return true
        }
        guard drawn else { throw ClipError.message("The video frame could not be converted.") }
        var frame = Data(capacity: side * side * 2)
        for pixel in stride(from: 0, to: rgba.count, by: 4) {
            let color = UInt16(rgba[pixel] & 0xf8) << 8 |
                UInt16(rgba[pixel + 1] & 0xfc) << 3 | UInt16(rgba[pixel + 2] >> 3)
            frame.append(UInt8(truncatingIfNeeded: color))
            frame.append(UInt8(color >> 8))
        }
        return frame
    }
}

private enum ClipError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

private struct DisplayReply {
    let status: Int
    let detail: String
}

/// One HTTP POST to the display, sent straight over the Wi-Fi interface.
/// iOS keeps mobile data as its main route while the Clip Wi-Fi has no internet,
/// so the connection is pinned to Wi-Fi instead of following the system route.
private final class DisplayRequest: @unchecked Sendable {
    private static let address = "192.168.9.1"
    private static let separator = Data("\r\n\r\n".utf8)

    private let connection: NWConnection
    private let payload: Data
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.orbitcube.display")
    private var received = Data()
    private var lastProblem: Error?
    private var continuation: CheckedContinuation<DisplayReply, Error>?
    private var finished = false

    init(path: String, body: Data, timeout: TimeInterval) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredInterfaceType = .wifi
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.preferNoProxies = true
        connection = NWConnection(host: NWEndpoint.Host(Self.address), port: 80, using: parameters)
        let head = "POST \(path) HTTP/1.1\r\nHost: \(Self.address)\r\n" +
            "Content-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n"
        var request = Data(head.utf8)
        request.append(body)
        payload = request
        self.timeout = timeout
    }

    func run() async throws -> DisplayReply {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<DisplayReply, Error>) in
                queue.async {
                    if self.finished {
                        waiter.resume(throwing: CancellationError())
                    } else {
                        self.continuation = waiter
                        self.start()
                    }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func start() {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.connection.send(content: self.payload, completion: .contentProcessed { error in
                    if let error { self.finish(.failure(error)) }
                })
                self.receive()
            case .waiting(let error):
                self.lastProblem = error
            case .failed(let error):
                self.finish(.failure(error))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            if let problem = self.lastProblem {
                self.finish(.failure(problem))
            } else {
                self.finish(.failure(ClipError.message("The display did not answer in time. Stay on its Clip Wi-Fi and keep the phone close to the display.")))
            }
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            if let data { self.received.append(data) }
            if isComplete || self.replyIsComplete() {
                self.finish(Result { try self.parseReply() })
            } else if let error {
                self.finish(.failure(error))
            } else {
                self.receive()
            }
        }
    }

    private func headerEnd() -> Range<Data.Index>? {
        received.range(of: Self.separator)
    }

    private func replyIsComplete() -> Bool {
        guard let end = headerEnd() else { return false }
        let head = String(decoding: received[received.startIndex..<end.lowerBound], as: UTF8.self)
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length",
               let length = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                return received.distance(from: end.upperBound, to: received.endIndex) >= length
            }
        }
        return false
    }

    private func parseReply() throws -> DisplayReply {
        guard let end = headerEnd() else {
            throw ClipError.message("The display closed the connection without a reply.")
        }
        let head = String(decoding: received[received.startIndex..<end.lowerBound], as: UTF8.self)
        let words = head.split(separator: " ", maxSplits: 2)
        guard words.count >= 2, let status = Int(words[1]) else {
            throw ClipError.message("The display sent a reply this app does not understand.")
        }
        let body = received[end.upperBound..<received.endIndex].prefix(160)
        return DisplayReply(status: status, detail: String(decoding: body, as: UTF8.self))
    }

    private func finish(_ result: Result<DisplayReply, Error>) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }
}
