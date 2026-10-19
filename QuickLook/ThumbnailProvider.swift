import AppKit
import QuickLookThumbnailing
import OSLog

@objc(UVZThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let image = try CoverRenderer.image(at: request.fileURL)
                let size = CoverRenderer.fitted(image, within: request.maximumSize)
                let reply = QLThumbnailReply(contextSize: size) { context in
                    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
                    context.interpolationQuality = .high; context.draw(image, in: CGRect(origin: .zero, size: size))
                    Logger(subsystem: "local.uvzreaderlab.rebuild.quicklook", category: "thumbnail").notice("UVZ cover thumbnail rendered: \(image.width, privacy: .public)x\(image.height, privacy: .public)")
                    return true
                }
                reply.extensionBadge = "UVZ"
                handler(reply, nil)
            } catch { handler(nil, error) }
        }
    }
}
