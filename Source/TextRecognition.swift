import AppKit
import Vision

struct RecognitionOptions {
    var language: String
    var layout: String
    static let languages = [("auto","自动语言"),("zh-Hans","简体中文"),("zh-Hant","繁體中文"),("ja-JP","日本語"),("en-US","English")]
    static let layouts = [("auto","自动排版"),("horizontal","横排"),("vertical","竖排（从右至左）")]
    static var saved: Self { .init(language:UserDefaults.standard.string(forKey:"ocr.language") ?? "auto",layout:UserDefaults.standard.string(forKey:"ocr.layout") ?? "auto") }
    func save() { UserDefaults.standard.set(language,forKey:"ocr.language"); UserDefaults.standard.set(layout,forKey:"ocr.layout") }
}
final class RecognitionControls {
    let language = NSPopUpButton(), layout = NSPopUpButton()
    init() {
        language.addItems(withTitles:RecognitionOptions.languages.map(\.1)); layout.addItems(withTitles:RecognitionOptions.layouts.map(\.1))
        let saved = RecognitionOptions.saved
        language.selectItem(at:RecognitionOptions.languages.firstIndex(where:{$0.0 == saved.language}) ?? 0)
        layout.selectItem(at:RecognitionOptions.layouts.firstIndex(where:{$0.0 == saved.layout}) ?? 0)
        language.toolTip = "自动语言优先保留原文字形；识别不佳时可指定繁体、日文或英文。"
        layout.toolTip = "竖排按右列至左列、每列从上至下识别；混排可用框选识别缩小范围。"
    }
    var options: RecognitionOptions {
        let value = RecognitionOptions(language:RecognitionOptions.languages[max(0,language.indexOfSelectedItem)].0,layout:RecognitionOptions.layouts[max(0,layout.indexOfSelectedItem)].0)
        value.save(); return value
    }
}

/// Shared local OCR. Reflow upright vertical glyphs instead of rotating the glyphs sideways.
enum TextRecognition {
    static func request(_ image: CGImage,options: RecognitionOptions, orientation: CGImagePropertyOrientation = .up) throws -> [PageInspection.EvidenceLine] {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        let supported = try request.supportedRecognitionLanguages()
        let preferred = options.language == "auto" ? ["zh-Hant","zh-Hans","ja-JP","en-US","fr-FR","de-DE","ko-KR"] : [options.language,"en-US"]
        request.recognitionLanguages = preferred.filter { supported.contains($0) }
        request.automaticallyDetectsLanguage = options.language == "auto"
        request.customWords = ["文库","丛书","出版社","书名","出版日期","頁數","文庫","叢書","書名","出版者","著者","発行所","発行日","シリーズ","ISBN"]
        request.minimumTextHeight = 0.004
        try VNImageRequestHandler(cgImage:image,orientation:orientation,options:[:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let value = observation.topCandidates(1).first else { return nil }
            let b = observation.boundingBox,box: CGRect
            switch orientation {
            case .right: box = CGRect(x:1-b.maxY,y:b.minX,width:b.height,height:b.width)
            case .left: box = CGRect(x:b.minY,y:1-b.maxX,width:b.height,height:b.width)
            default:box = b
            }
            return .init(text:value.string,box:box,confidence:value.confidence,vertical:orientation != .up)
        }
    }
    private static func refined(_ image: CGImage,options: RecognitionOptions) throws -> [PageInspection.EvidenceLine] {
        var lines = try request(image,options:options),count = 0
        for index in lines.indices {
            let line = lines[index]
            guard count<8,line.confidence<0.35,line.text.count>=4,line.box.width>line.box.height*2 else { continue }
            let b = line.box.insetBy(dx:-0.005,dy:-0.004).intersection(CGRect(x:0,y:0,width:1,height:1))
            guard let crop = image.cropping(to:CGRect(x:b.minX*CGFloat(image.width),y:(1-b.maxY)*CGFloat(image.height),width:b.width*CGFloat(image.width),height:b.height*CGFloat(image.height)).integral) else { continue }
            count += 1
            let scale = max(1,min(3,1800/CGFloat(crop.width))),w = max(1,Int(CGFloat(crop.width)*scale)),h = max(1,Int(CGFloat(crop.height)*scale))
            guard let context = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            context.interpolationQuality = .high;context.draw(crop,in:CGRect(x:0,y:0,width:w,height:h))
            guard let enlarged = context.makeImage(),let retry = try? request(enlarged,options:options),!retry.isEmpty else { continue }
            let text = ordered(retry).map(\.text).joined(separator:" "),confidence = retry.map(\.confidence).reduce(0,+)/Float(retry.count)
            guard confidence>line.confidence,text.count>=line.text.count*3/4,text.count<=line.text.count*5/4+2 else { continue }
            lines[index] = .init(text:text,box:line.box,confidence:confidence)
        }
        return lines
    }
    static func ordered(_ lines: [PageInspection.EvidenceLine]) -> [PageInspection.EvidenceLine] {
        if lines.filter(\.vertical).count>lines.count/2 {
            return lines.sorted { abs($0.box.midX-$1.box.midX)>0.015 ? $0.box.midX>$1.box.midX : $0.box.midY>$1.box.midY }
        }
        return lines.sorted { abs($0.box.midY-$1.box.midY)>0.012 ? $0.box.midY>$1.box.midY : $0.box.minX<$1.box.minX }
    }
    static func lines(_ image: CGImage,options: RecognitionOptions = .saved) throws -> [PageInspection.EvidenceLine] {
        let horizontal = try refined(image,options:options)
        let nativeText = horizontal.map(\.text).joined(separator:" ")
        let latin = nativeText.filter { $0.isASCII && $0.isLetter }.count
        if nativeText.range(of:"[\\p{Han}\\p{Hiragana}\\p{Katakana}]",options:.regularExpression) == nil,latin>20,horizontal.filter({$0.text.count>=4}).count>=2 {
            // Vision already understands rotated Latin lines. Reflowing those letters would scramble words.
            return horizontal.map { .init(text:$0.text,box:$0.box,confidence:$0.confidence,vertical:$0.box.height>$0.box.width*2) }
        }
        // Latin vertical headings are commonly rotated as a whole rather than set glyph by glyph.
        if options.language == "en-US",options.layout != "horizontal" {
            func score(_ lines: [PageInspection.EvidenceLine]) -> Float {
                lines.reduce(0) { partial,line in
                    let label = line.text.range(of:"(?i)^(?:Title|Author|Publisher|Series|Publication date|Pages|ISBN)[ :：]",options:.regularExpression) != nil
                    return partial+Float(line.text.filter {$0.isLetter || $0.isNumber}.count)*line.confidence+(label ? 60 : 0)
                }
            }
            let rotations = try [CGImagePropertyOrientation.left,.right].map { try request(image,options:options,orientation:$0) }
            if let best = rotations.max(by:{score($0)<score($1)}),score(best)>score(horizontal)*1.02 { return ordered(best) }
        }
        guard options.layout != "horizontal" else { return ordered(horizontal) }
        let columns = verticalColumns(image,forced:options.layout == "vertical")
        guard !columns.isEmpty else { return ordered(horizontal) }
        var result = horizontal
        for column in columns.prefix(24) {
            if options.layout == "auto" {
                let box = CGRect(x:column.minX/CGFloat(image.width),y:1-column.maxY/CGFloat(image.height),width:column.width/CGFloat(image.width),height:column.height/CGFloat(image.height))
                let crossings = horizontal.filter { $0.text.count>=4 && $0.confidence>=0.4 && $0.box.width>box.width*2 && $0.box.intersects(box) }
                if crossings.count>=2 { continue }
            }
            guard let row = reflow(image,column:column) else { continue }
            let recognized = try request(row,options:options)
            let text = ordered(recognized).map(\.text).joined().replacingOccurrences(of:"(?<=\\p{Han})\\s+(?=\\p{Han})",with:"",options:.regularExpression)
            guard text.count>=3 else { continue }
            let confidence = recognized.map(\.confidence).reduce(0,+)/Float(max(1,recognized.count))
            let box = CGRect(x:column.minX/CGFloat(image.width),y:1-column.maxY/CGFloat(image.height),width:column.width/CGFloat(image.width),height:column.height/CGFloat(image.height))
            // In automatic mode require actual vertical geometry. Horizontal body text is retained.
            result.removeAll { box.insetBy(dx:-0.005,dy:-0.005).contains(CGPoint(x:$0.box.midX,y:$0.box.midY)) }
            result.append(.init(text:text,box:box,confidence:confidence,vertical:true))
        }
        return ordered(result)
    }
    private static func runs(_ counts: [Int],threshold: Int,gap: Int) -> [Range<Int>] {
        let active = counts.indices.filter { counts[$0]>=threshold }
        guard let first = active.first else { return [] }
        var output: [Range<Int>] = [], start = first, end = first
        for index in active.dropFirst() {
            if index-end>gap+1 { output.append(start..<end+1); start = index }
            end = index
        }
        output.append(start..<end+1); return output
    }
    private static func pixels(_ image: CGImage,maxSide: CGFloat = 1800) -> (Int,Int,[UInt8])? {
        let scale = min(1,maxSide/CGFloat(max(image.width,image.height))),w = max(1,Int(CGFloat(image.width)*scale)),h = max(1,Int(CGFloat(image.height)*scale))
        var data = [UInt8](repeating:255,count:w*h)
        let ok = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let c = CGContext(data:bytes.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return false }
            c.setFillColor(gray:1,alpha:1); c.fill(CGRect(x:0,y:0,width:w,height:h)); c.draw(image,in:CGRect(x:0,y:0,width:w,height:h)); return true
        }
        return ok ? (w,h,data) : nil
    }
    static func verticalColumns(_ image: CGImage,forced: Bool) -> [CGRect] {
        guard let (w,h,data) = pixels(image) else { return [] }
        var projection = [Int](repeating:0,count:w)
        for y in 0..<h { for x in 0..<w where data[y*w+x]<160 { projection[x] += 1 } }
        let bands = runs(projection,threshold:max(5,h/180),gap:max(2,w/250))
        var output: [CGRect] = []
        for band in bands where band.count>=max(7,w/200) && band.count<w/5 {
            var rows = [Int](repeating:0,count:h)
            for y in 0..<h { for x in band where data[y*w+x]<160 { rows[y] += 1 } }
            let spans = runs(rows,threshold:max(2,band.count/15),gap:max(1,band.count/8))
            guard let first = spans.first,let last = spans.last else { continue }
            let height = last.upperBound-first.lowerBound
            let glyphs = spans.filter {$0.count>=band.count/3 && $0.count<=band.count*2}
            guard height>band.count*3,forced || (glyphs.count>=4 && Double(glyphs.count)/Double(spans.count)>0.65) else { continue }
            // Projection memory uses the same top-left pixel order as CGImage cropping.
            let sx = CGFloat(image.width)/CGFloat(w),sy = CGFloat(image.height)/CGFloat(h)
            output.append(CGRect(x:CGFloat(band.lowerBound)*sx,y:CGFloat(first.lowerBound)*sy,width:CGFloat(band.count)*sx,height:CGFloat(height)*sy).insetBy(dx:-2,dy:-2).intersection(CGRect(x:0,y:0,width:image.width,height:image.height)))
        }
        return output.sorted {$0.minX>$1.minX}
    }
    static func reflow(_ image: CGImage,column: CGRect) -> CGImage? {
        guard let crop = image.cropping(to:column.integral),let (w,h,data) = pixels(crop,maxSide:2400) else { return nil }
        var rows = [Int](repeating:0,count:h)
        for y in 0..<h { for x in 0..<w where data[y*w+x]<160 { rows[y] += 1 } }
        let spans = runs(rows,threshold:max(2,w/15),gap:max(1,w/8))
        guard spans.count>=3,spans.count<=80 else { return nil }
        // Internal strokes can produce short spans; combine into glyph-height cells.
        var cells: [Range<Int>] = [],start = spans[0].lowerBound,end = spans[0].upperBound
        for span in spans.dropFirst() {
            if span.upperBound-start<=Int(Double(w)*1.05) { end = span.upperBound }
            else { cells.append(start..<end); start = span.lowerBound; end = span.upperBound }
        }
        cells.append(start..<end)
        let size = max(32,min(160,w)),padding = 6,canvasWidth = (size+padding)*cells.count+padding
        guard let context = CGContext(data:nil,width:canvasWidth,height:size+padding*2,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(gray:1,alpha:1);context.fill(CGRect(x:0,y:0,width:canvasWidth,height:size+padding*2))
        for (index,cell) in cells.enumerated() {
            let sy = CGFloat(crop.height)/CGFloat(h)
            guard let glyph = crop.cropping(to:CGRect(x:0,y:CGFloat(cell.lowerBound)*sy,width:CGFloat(crop.width),height:CGFloat(cell.count)*sy)) else { continue }
            let ratio = min(CGFloat(size)/CGFloat(glyph.width),CGFloat(size)/CGFloat(glyph.height)),gw = CGFloat(glyph.width)*ratio,gh = CGFloat(glyph.height)*ratio
            context.draw(glyph,in:CGRect(x:CGFloat(padding+index*(size+padding))+(CGFloat(size)-gw)/2,y:CGFloat(padding)+(CGFloat(size)-gh)/2,width:gw,height:gh))
        }
        return context.makeImage()
    }
}
