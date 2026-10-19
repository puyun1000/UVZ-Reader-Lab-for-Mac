import AppKit
import PDFKit

/// Read-only and shared by both system extensions. No app process or OCR is started.
enum CoverRenderer {
    static func image(at url: URL) throws -> CGImage {
        guard url.pathExtension.lowercased() == "uvz" else { throw ReaderFailure("此预览扩展用于 UVZ 图书。") }
        let book = try BookArchive(url: url)
        let covers = book.pages.indices.filter { book.pages[$0].key.group == 0 }
        let candidates = Array((covers.isEmpty ? Array(book.pages.indices.prefix(3)) : Array(covers.prefix(3))))
        var failure: Error = ReaderFailure("图书没有可预览的页面。")
        for page in candidates {
            do { return try book.pageImage(at: page) } catch { failure = error }
        }
        throw failure
    }
    static func fitted(_ image: CGImage, within maximum: CGSize) -> CGSize {
        let ratio = min(maximum.width / CGFloat(image.width), maximum.height / CGFloat(image.height))
        return CGSize(width: max(1, CGFloat(image.width) * ratio), height: max(1, CGFloat(image.height) * ratio))
    }
}
