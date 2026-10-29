import Foundation
import ImageIO
import PDFKit

@_silgen_name("lab_deflate_bound") private func exportDeflateBound(_ count: Int) -> Int
@_silgen_name("lab_deflate_zlib") private func exportDeflate(_ input: UnsafePointer<UInt8>,_ count: Int,_ output: UnsafeMutablePointer<UInt8>,_ capacity: Int) -> Int

struct ExportImage {
    let bytes: Data
    let width: Int, height: Int, bits: Int
    let colors: Int
    let jpeg: Bool
    let orientation: Int
    let dpiX: Double,dpiY: Double
    let usedFallbackDPI: Bool
    var icc: Data? = nil
    var pageSize: CGSize {
        let w = Double(width)*72/dpiX,h = Double(height)*72/dpiY
        return (5...8).contains(orientation) ? CGSize(width:h,height:w) : CGSize(width:w,height:h)
    }
    var drawingMatrix: [Double] {
        let w = Double(width)*72/dpiX,h = Double(height)*72/dpiY
        let matrix: [Double]
        switch orientation {
        case 2:matrix = [-w,0,0,h,w,0]
        case 3:matrix = [-w,0,0,-h,w,h]
        case 4:matrix = [w,0,0,-h,0,h]
        case 5:matrix = [0,-w,-h,0,h,w]
        case 6:matrix = [0,-w,h,0,0,w]
        case 7:matrix = [0,w,h,0,0,0]
        case 8:matrix = [0,w,-h,0,h,0]
        default:matrix = [w,0,0,h,0,0]
        }
        return matrix
    }
    static func make(data: Data?, image: @autoclosure () throws -> CGImage, fallbackDPI: Double, imageIndex: Int = 0, sourceDPI:Double? = nil) throws -> Self {
        var props: [CFString:Any] = [:]
        if let data,let src = CGImageSourceCreateWithData(data as CFData,nil) { props = CGImageSourceCopyPropertiesAtIndex(src,imageIndex,nil) as? [CFString:Any] ?? [:] }
        let known=sourceDPI ?? data.flatMap {DjVuPageProperties.singlePage($0).map {Double($0.dpi)}}
        let dx = props[kCGImagePropertyDPIWidth] as? Double ?? known,dy = props[kCGImagePropertyDPIHeight] as? Double ?? known
        func valid(_ value:Double?) -> Bool {value.map {$0.isFinite && (25...6000).contains($0)} ?? false}
        func dpi(_ value: Double?) -> Double {valid(value) ? value! : fallbackDPI}
        let missing = !valid(dx) || !valid(dy),orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        if let data,data.starts(with:[0xff,0xd8]),let w = props[kCGImagePropertyPixelWidth] as? Int,let h = props[kCGImagePropertyPixelHeight] as? Int,w>0,h>0,w<=30000,h<=30000,w*h<=60_000_000,
           let model = props[kCGImagePropertyColorModel] as? String,["Gray","RGB"].contains(model), (props[kCGImagePropertyDepth] as? Int ?? 8) == 8 {
            // Header metadata alone also succeeds for truncated JPEG streams.
            // Decode for integrity, then retain the original compressed bytes.
            _ = try PageDecoder.image(data,applyOrientation:false)
            return Self(bytes:data,width:w,height:h,bits:8,colors:model == "Gray" ? 1 : 3,jpeg:true,orientation:orientation,dpiX:dpi(dx),dpiY:dpi(dy),usedFallbackDPI:missing,icc:jpegICC(data))
        }
        // Reuse the already decoded payload, including corrected photo PNGs.
        // Export applies its orientation matrix once, independently of reading/OCR.
        let cg = try data.map {try PageDecoder.image($0,pdfPage:imageIndex,applyOrientation:false)} ?? image(),w = cg.width,h = cg.height
        guard cg.bitsPerComponent<=8,(props[kCGImagePropertyDepth] as? Int ?? 8)<=8 else {throw ReaderFailure("此页位深超过8位，本版暂不支持其无损转换，未降低精度。请保留原书。") }
        guard w>0,h>0,w<=30000,h<=30000,w*h<=60_000_000 else { throw ReaderFailure("页面尺寸超过转换限制。") }
        let gray = cg.colorSpace?.model == .monochrome
        let channels = gray ? 1 : 4,stride = w*channels
        var raw = Data(count:stride*h)
        let ok = raw.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data:buffer.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:stride,space:gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),bitmapInfo:gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.setFillColor(gray:1,alpha:1);context.fill(CGRect(x:0,y:0,width:w,height:h));context.draw(cg,in:CGRect(x:0,y:0,width:w,height:h));return true
        }
        guard ok else { throw ReaderFailure("无法创建无损图像缓冲区。") }
        var pixels = raw
        if !gray {
            pixels = Data(count:w*h*3)
            pixels.withUnsafeMutableBytes { dst in raw.withUnsafeBytes { src in
                let a = src.bindMemory(to:UInt8.self),b = dst.bindMemory(to:UInt8.self)
                for i in 0..<w*h { b[i*3]=a[i*4];b[i*3+1]=a[i*4+1];b[i*3+2]=a[i*4+2] }
            } }
        }
        // Preserve monochrome scans losslessly in 1 bit when their decoded samples are binary.
        var bits = 8
        if gray,pixels.allSatisfy({$0 == 0 || $0 == 255}) {
            let row = (w+7)/8;var packed = Data(repeating:255,count:row*h)
            for y in 0..<h { for x in 0..<w where pixels[y*w+x] == 0 { packed[y*row+x/8] &= ~(UInt8(1) << (7-x%8)) } }
            pixels = packed;bits = 1
        }
        var packed = Data(count:exportDeflateBound(pixels.count))
        let capacity = packed.count
        let count = packed.withUnsafeMutableBytes { dst in pixels.withUnsafeBytes { src in exportDeflate(src.baseAddress!.assumingMemoryBound(to:UInt8.self),pixels.count,dst.baseAddress!.assumingMemoryBound(to:UInt8.self),capacity) } }
        guard count>0 else { throw ReaderFailure("无损图像压缩失败。") };packed.count = count
        return Self(bytes:packed,width:w,height:h,bits:bits,colors:gray ? 1 : 3,jpeg:false,orientation:orientation,dpiX:dpi(dx),dpiY:dpi(dy),usedFallbackDPI:missing)
    }
    private static func jpegICC(_ bytes: Data) -> Data? {
        var at = 2,parts: [Int:Data] = [:],total = 0
        while at+4<=bytes.count {
            guard bytes[at] == 255 else { break };let marker = bytes[at+1];at += 2
            if marker == 0xda || marker == 0xd9 { break }
            if marker == 0x01 || (0xd0...0xd7).contains(marker) { continue }
            let length = Int(bytes[at])*256+Int(bytes[at+1]);guard length>=2,at+length<=bytes.count else { break }
            if marker == 0xe2,length>=16,bytes.subdata(in:at+2..<at+14) == Data("ICC_PROFILE\0".utf8) {
                let index = Int(bytes[at+14]);total = Int(bytes[at+15]);parts[index] = bytes.subdata(in:at+16..<at+length)
            }
            at += length
        }
        guard total>0,total<=255,parts.count == total else { return nil }
        return (1...total).reduce(into:Data()) { $0.append(parts[$1] ?? Data()) }
    }
}

/// Stream each page to disk; only offsets, page identities and outline nodes remain in memory.
final class PDFExportWriter {
    private let handle: FileHandle
    private var offsets: [UInt64] = [0,0,0,0,0]
    private var position: UInt64 = 0
    private(set) var pages: [Int] = []
    private var closed = false
    init(_ url: URL) throws {
        guard FileManager.default.createFile(atPath:url.path,contents:nil) else { throw ReaderFailure("无法创建临时PDF。") }
        handle = try FileHandle(forWritingTo:url);try write(Data("%PDF-1.7\n%\u{00e2}\u{00e3}\u{00cf}\u{00d3}\n".utf8))
    }
    deinit { try? handle.close() }
    private func allocate() -> Int { offsets.append(0);return offsets.count-1 }
    private func write(_ data: Data) throws { try handle.write(contentsOf:data);position += UInt64(data.count) }
    private func object(_ id: Int,_ text: String) throws { try object(id,Data(text.utf8)) }
    private func object(_ id: Int,_ bytes: Data) throws { offsets[id] = position;try write(Data("\(id) 0 obj\n".utf8));try write(bytes);try write(Data("\nendobj\n".utf8)) }
    private func stream(_ id: Int,_ header: String,_ bytes: Data) throws {
        offsets[id] = position;try write(Data("\(id) 0 obj\n<< \(header) /Length \(bytes.count) >>\nstream\n".utf8));try write(bytes);try write(Data("\nendstream\nendobj\n".utf8))
    }
    static func string(_ value: String) -> String { "<FEFF"+value.utf16.map {String(format:"%04X",$0)}.joined()+">" }
    static func info(_ metadata: [String:String]) throws -> String {
        let encoded = String(decoding:try JSONEncoder().encode(metadata),as:UTF8.self)
        let fields = NativeDocumentMetadata.mapping.sorted {$0.key<$1.key}.compactMap { key,name in metadata[key].map {"/"+name+" "+string($0)} }.joined(separator:"\n")
        return "<< /Producer \(string("UVZ Reader Lab")) /CreationDate (D:\(date())) \(fields) /UVZReaderLabMetadata \(string(encoded)) >>"
    }
    private static func date() -> String { let f = DateFormatter();f.locale = Locale(identifier:"en_US_POSIX");f.timeZone = TimeZone(secondsFromGMT:0);f.dateFormat = "yyyyMMddHHmmss'Z'";return f.string(from:Date()) }
    func append(_ image: ExportImage) throws {
        let page = allocate(),content = allocate(),raster = allocate(),size = image.pageSize
        var color = image.colors == 1 ? "/DeviceGray" : "/DeviceRGB"
        if let icc = image.icc { let id = allocate();try stream(id,"/N \(image.colors) /Alternate \(color)",icc);color = "[/ICCBased \(id) 0 R]" }
        try stream(raster,"/Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) /ColorSpace \(color) /BitsPerComponent \(image.bits) /Filter \(image.jpeg ? "/DCTDecode" : "/FlateDecode")",image.bytes)
        let matrix = image.drawingMatrix
        try stream(content,"",Data(("q "+matrix.map {String(format:"%.5f",locale:Locale(identifier:"en_US_POSIX"),$0)}.joined(separator:" ")+" cm /Image Do Q\n").utf8))
        try object(page,"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(size.width) \(size.height)] /Resources << /XObject << /Image \(raster) 0 R >> >> /Contents \(content) 0 R >>")
        pages.append(page)
    }
    func finish(metadata: [String:String],chapters: [BookChapter],map: [Int:Int]) throws {
        guard !closed,!pages.isEmpty else { throw ReaderFailure("没有可输出的页面。") }
        final class Node {
            let id: Int,chapter: BookChapter
            var parent = 4,children: [Node] = [],previous: Int?,next: Int?
            init(_ id:Int,_ chapter:BookChapter) { self.id=id;self.chapter=chapter }
            var descendants: Int { children.reduce(0) {$0+1+$1.descendants} }
        }
        var roots: [Node] = [],all: [Node] = [],stack: [Node] = []
        for chapter in chapters {
            let node = Node(allocate(),chapter),level = max(0,min(63,chapter.level))
            while stack.count>level {stack.removeLast()}
            if let parent = stack.last {node.parent=parent.id;if let prev=parent.children.last {node.previous=prev.id;prev.next=node.id};parent.children.append(node)}
            else {if let prev=roots.last {node.previous=prev.id;prev.next=node.id};roots.append(node)}
            stack.append(node);all.append(node)
        }
        for node in all {
            var text = "/Title \(Self.string(node.chapter.title)) /Parent \(node.parent) 0 R"
            if let prev=node.previous {text += " /Prev \(prev) 0 R"};if let next=node.next {text += " /Next \(next) 0 R"}
            if let first=node.children.first,let last=node.children.last {text += " /First \(first.id) 0 R /Last \(last.id) 0 R /Count \(node.descendants)"}
            if let index=map[node.chapter.pageIndex],pages.indices.contains(index) {text += " /Dest [\(pages[index]) 0 R /XYZ null null null]"}
            try object(node.id,"<< \(text) >>")
        }
        try object(4,"<< /Type /Outlines /Count \(all.count)"+(roots.first.map {" /First \($0.id) 0 R /Last \(roots.last!.id) 0 R"} ?? "")+" >>")
        try object(1,"<< /Type /Catalog /Pages 2 0 R"+(all.isEmpty ? "" : " /Outlines 4 0 R /PageMode /UseOutlines")+" >>")
        try object(2,"<< /Type /Pages /Count \(pages.count) /Kids ["+pages.map {"\($0) 0 R"}.joined(separator:" ")+"] >>")
        try object(3,try Self.info(metadata))
        let xref = position;try write(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {guard offset<10_000_000_000 else {throw ReaderFailure("PDF超过当前写入大小限制。")};try write(Data(String(format:"%010llu 00000 n \n",offset).utf8))}
        try write(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R /Info 3 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8));try handle.synchronize();try handle.close();closed=true
    }
}
