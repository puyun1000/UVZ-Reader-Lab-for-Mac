import AppKit
import Vision

struct InspectionTarget: Hashable, Codable {
    let title: String
    let group: Int
    let number: Int
}
struct PageFinding: Codable, Equatable {
    let id: String
    let text: String
    let page: Int? // One-based physical page, when there is image evidence.
    let suggestedGroup: Int?
    let suggestedNumber: Int?
    var suggestion: PageCorrection? {
        guard let page, let group = suggestedGroup, let number = suggestedNumber else { return nil }
        return PageCorrection(page:page,group:group,number:number)
    }
}
enum PageInspection {
    static func structural(_ book: BookArchive) -> [PageFinding] {
        guard book.usesPDGNumbering else { return [] }
        var result: [PageFinding] = []
        for group in 0..<9 {
            let indices = book.pages.indices.filter { book.pages[$0].key.group == group }
            let grouped = Dictionary(grouping:indices,by:{ book.pages[$0].number })
            let numbers = grouped.keys.sorted()
            for (a,b) in zip(numbers,numbers.dropFirst()) where b > a+1 {
                let gap = b == a+2 ? String(a+1) : "\(a+1)—\(b-1)"
                result.append(PageFinding(id:"gap:\(group):\(gap)",text:"\(PageAddressing.titles[group])页号 \(gap) 断号（相邻 \(a)、\(b)）。可能是缺页或页面归错类型，需查看图像核对。",page:nil,suggestedGroup:nil,suggestedNumber:nil))
            }
            for number in numbers where grouped[number]!.count > 1 {
                result.append(PageFinding(id:"duplicate:\(group):\(number)",text:"\(PageAddressing.titles[group])第 \(number) 页对应多个文件，需纠正重号。",page:grouped[number]!.first!+1,suggestedGroup:nil,suggestedNumber:nil))
            }
            if group == 8, let first = indices.first { result.append(PageFinding(id:"unknown",text:"存在无法识别页面类型的文件，可人工核对并改编码。",page:first+1,suggestedGroup:nil,suggestedNumber:nil)) }
        }
        if let notice = book.contentsNotice { result.append(PageFinding(id:"contents-notice",text:notice,page:nil,suggestedGroup:nil,suggestedNumber:nil)) }
        return result
    }
    static func targets(_ book: BookArchive) -> [InspectionTarget] {
        guard let raw = try? book.contentsData(), let text = try? BookArchive.contentsText(raw) else { return [] }
        let map = PageAddressing(book)
        return text.components(separatedBy:.newlines).compactMap { line in
            let fields = line.components(separatedBy:"|")
            guard fields.count >= 5, let number = Int(fields[2].trimmingCharacters(in:.whitespaces)), let type = Int(fields[4].trimmingCharacters(in:.whitespaces)), (1...8).contains(type), number > 0 else { return nil }
            let token = PageAddressing.prefixes[type-1]+String(number)
            guard (try? map.resolve(token)) == nil else { return nil }
            return InspectionTarget(title:fields[0],group:type-1,number:number)
        }
    }
    static func normalized(_ text: String) -> String {
        let value = text.precomposedStringWithCompatibilityMapping.applyingTransform(StringTransform("Traditional-Simplified"),reverse:false) ?? text
        return String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    struct EvidenceLine { let text: String; let box: CGRect; let confidence: Float; var vertical = false }
    static func lines(_ image: CGImage, marginOnly: Bool = false) throws -> [EvidenceLine] {
        try TextRecognition.lines(image,options:RecognitionOptions(language:"auto",layout:"horizontal")).filter { !marginOnly || $0.box.minY>0.84 }
    }
    static func printedNumber(_ lines: [EvidenceLine]) -> Int? {
        let pattern = try! NSRegularExpression(pattern:"^([0-9]{1,6})(?:[ \\t｜|]+[^0-9].*)?$")
        let candidates = lines.compactMap { line -> Int? in
            guard line.confidence >= 0.9, line.box.minY > 0.84 || line.box.maxY < 0.15 else { return nil }
            let text = line.text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in:.whitespaces)
            guard let match = pattern.firstMatch(in:text,range:NSRange(location:0,length:(text as NSString).length)) else { return nil }
            return Int((text as NSString).substring(with:match.range(at:1)))
        }
        let values = Set(candidates.filter { $0 > 0 })
        return values.count == 1 ? values.first : nil
    }
    static func currentPage(_ book: BookArchive, index: Int, image: CGImage) throws -> [PageFinding] {
        guard book.usesPDGNumbering, book.pages[index].key.group == 5,
              let printed = printedNumber(try lines(image,marginOnly:true)), printed != book.pages[index].number else { return [] }
        return [PageFinding(id:"printed:\(index)",text:"疑似错编：\(book.pages[index].name) 编为正文 \(book.pages[index].number)，页眉识别到 \(printed)。请核对原图，识别结果可能有误。",page:index+1,suggestedGroup:5,suggestedNumber:printed)]
    }
    static func titleMatches(_ evidence: [EvidenceLine], targets: [InspectionTarget], page: Int, name: String) -> [PageFinding] {
        // Mentions inside a long preface are not evidence that it is a title page.
        guard evidence.count <= 16 else { return [] }
        let matches = targets.filter { target in
            let title = normalized(target.title)
            guard title.count >= 4 else { return false }
            return evidence.contains { line in line.confidence >= 0.1 && normalized(line.text).contains(title) }
        }
        // A directory list often contains many titles and is not an inferred target image.
        guard matches.count <= 2 else { return [] }
        return matches.map { target in
            PageFinding(id:"title:\(page):\(target.group):\(target.number)",text:"疑似归错类型：\(name) 的识别文字含“\(target.title)”，目录目标为\(PageAddressing.titles[target.group]) \(target.number)。请对照图像确认后再纠正。",page:page,suggestedGroup:target.group,suggestedNumber:target.number)
        }
    }
    static func directoryLines(_ image: CGImage) throws -> [EvidenceLine] {
        var evidence = try lines(image)
        // Dot leaders often make whole-page OCR omit the right-hand page-number column.
        let rect = CGRect(x:CGFloat(image.width)*0.76,y:0,width:CGFloat(image.width)*0.24,height:CGFloat(image.height)).integral
        guard let right = image.cropping(to:rect) else { return evidence }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = false; request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage:right,options:[:]).perform([request])
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first,
                  text.string.range(of:"^[0-9]{1,6}$",options:.regularExpression) != nil else { continue }
            let box = observation.boundingBox
            let global = CGRect(x:rect.minX/CGFloat(image.width)+box.minX*rect.width/CGFloat(image.width),y:box.minY,width:box.width*rect.width/CGFloat(image.width),height:box.height)
            if !evidence.contains(where:{ normalized($0.text) == normalized(text.string) && abs($0.box.midY-global.midY)<0.01 }) {
                evidence.append(EvidenceLine(text:text.string,box:global,confidence:text.confidence))
            }
        }
        return evidence
    }
    static func scan(_ book: BookArchive, extra: [InspectionTarget] = [], limit: Int = 64, cancelled: () -> Bool = { false }, progress: (Int,Int) -> Void = { _,_ in }) throws -> [PageFinding] {
        guard book.usesPDGNumbering else { return [] }
        var targets = Array(Set(Self.targets(book)+extra)), result = structural(book)
        let map = PageAddressing(book)
        let directories = Array(book.pages.indices.filter { book.pages[$0].key.group == 4 }.prefix(12))
        let candidates = Array(book.pages.indices.filter { [1,3,6,8].contains(book.pages[$0].key.group) }.prefix(max(0,limit)))
        let total = directories.count + candidates.count
        for (offset,index) in directories.enumerated() {
            if cancelled() { return result }; progress(offset,total)
            guard let evidence = try? directoryLines(book.pageImage(at:index)) else { result.append(PageFinding(id:"unreadable:\(index)",text:"\(book.pages[index].name) 未能完成文字核对，请人工查看。",page:index+1,suggestedGroup:nil,suggestedNumber:nil)); continue }
            let text = ContentsOCRText.prepare(ContentsRegionRecognizer.assemble(evidence.map { .init(text:$0.text,box:$0.box) }))
            for line in text.components(separatedBy:.newlines) {
                let fields = line.components(separatedBy:"\t")
                guard fields.count >= 2, let number = Int(fields.last!.trimmingCharacters(in:.whitespaces)), number > 0,
                      (try? map.resolve(String(number))) == nil else { continue }
                let target = InspectionTarget(title:fields.dropLast().joined(separator:" ").trimmingCharacters(in:.whitespaces),group:5,number:number)
                if !targets.contains(target) { targets.append(target) }
            }
        }
        for (offset,index) in candidates.enumerated() {
            if cancelled() { return result }; progress(directories.count+offset,total)
            guard let evidence = try? lines(book.pageImage(at:index)) else { result.append(PageFinding(id:"unreadable:\(index)",text:"\(book.pages[index].name) 未能完成文字核对，请人工查看。",page:index+1,suggestedGroup:nil,suggestedNumber:nil)); continue }
            result.append(contentsOf:titleMatches(evidence,targets:targets,page:index+1,name:book.pages[index].name))
        }
        progress(total,total)
        if book.pages.filter({ [1,3,6,8].contains($0.key.group) }).count > candidates.count {
            result.append(PageFinding(id:"scan-limit",text:"本次检查了前 \(candidates.count) 张候选页面；其余页面尚未作内容核对。",page:nil,suggestedGroup:nil,suggestedNumber:nil))
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }.enumerated().sorted { a,b in
            let first = a.element.suggestion != nil, second = b.element.suggestion != nil
            return first != second ? first : a.offset < b.offset
        }.map(\.element)
    }
}
