import AVFoundation
import CoreTransferable
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
    private static let endpoint = URL(string: "http://192.168.9.1/frame")!

    static func play(_ url: URL, onFirstFrame: () -> Void) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ClipError.message("This file has no playable video.") }
        let images = AVAssetImageGenerator(asset: asset)
        images.appliesPreferredTrackTransform = true
        images.maximumSize = CGSize(width: 320, height: 320)
        images.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        images.requestedTimeToleranceAfter = .zero
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false
        config.timeoutIntervalForRequest = 4
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let interval = 0.16
        var position = 0.0
        while position < duration {
            try Task.checkCancellation()
            let start = DispatchTime.now().uptimeNanoseconds
            let frame = try await images.image(at: CMTime(seconds: position, preferredTimescale: 600)).image
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = try frameBytes(frame)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where error.code != .cancelled {
                throw ClipError.message("Cannot reach the display. Stay on its Clip Wi-Fi and allow Local Network access for Orbit Cube in iPhone Settings.")
            }
            guard let http = response as? HTTPURLResponse else { throw ClipError.message("The display did not reply.") }
            let detail = String(decoding: data.prefix(160), as: UTF8.self)
            guard http.statusCode == 200, detail == "OK" else {
                if http.statusCode == 409 { throw ClipError.message(detail) }
                if http.statusCode == 403 { throw ClipError.message("Join the Clip Wi-Fi shown on your display.") }
                throw ClipError.message("The display rejected the frame (HTTP \(http.statusCode)). \(detail)")
            }
            if position == 0 { onFirstFrame() }
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
