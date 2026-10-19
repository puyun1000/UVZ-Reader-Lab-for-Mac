import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import OSLog

@objc(UVZPreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest, completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let url = request.fileURL
        // The system runs this drawing closure off the request path and presents the
        // resulting page with its own preview toolbar, zoom and window behavior.
        let size = CGSize(width: 1000, height: 1400)
        let reply = QLPreviewReply(contextSize: size, isBitmap: false) { context, _ in
            let image = try CoverRenderer.image(at: url)
            let fitted = CoverRenderer.fitted(image, within: size)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height))
            Logger(subsystem: "local.uvzreaderlab.rebuild.quicklook", category: "preview").notice("UVZ cover preview rendered: \(image.width, privacy: .public)x\(image.height, privacy: .public)")
        }
        reply.title = url.deletingPathExtension().lastPathComponent
        handler(reply, nil)
    }
}
