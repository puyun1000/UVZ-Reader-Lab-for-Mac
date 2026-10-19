import AppKit

struct BibliographicValue: Codable {
    let field: String
    let value: String
    let source: String
    var inferred = false
}
struct BibliographicAnalysis {
    var values: [String:String]
    var evidence: [BibliographicValue]
    var notes: [String]
}
/// Parse description punctuation, not subject access entries or the CIP registration number.
/// GB/T 12451-2001 §§4–7; GB/T 12451-2023 §§5,7,8 and Appendix A.
/// Unknown layouts stay unresolved. No character or date is silently invented.
enum BibliographicExtraction {
    static func clean(_ text: String) -> String { text.trimmingCharacters(in:CharacterSet(charactersIn:" \t\n.。—－-、,，;；")) }
    static func normalize(_ text: String) -> String {
        var value = text.precomposedStringWithCompatibilityMapping.replacingOccurrences(of:"\r",with:"\n")
        // Normalize labels only; retain traditional characters in bibliographic values.
        for (a,b) in [("圖書在版編目","图书在版编目"),("數據","数据"),("書名","书名"),("叢書名","丛书名"),("出版時間","出版时间"),("出版日期","出版日期"),("出版發行","出版发行"),("頁數","页数"),("總頁數","总页数"),("責任編輯","责任编辑"),("版權","版权")] { value = value.replacingOccurrences(of:a,with:b) }
        return value.replacingOccurrences(of:"(?m)^(作|著|编)[ \\t]*\\n[ \\t]*(者|著)",with:"$1$2",options:.regularExpression)
    }
    static func first(_ pattern: String,_ text: String) -> String? { BookMetadata.captures(pattern,text).first?.first }
    static func validDate(_ text: String) -> String? {
        guard let groups = BookMetadata.captures("^([12][0-9]{3})(?:[.年/-]\\s*(0?[1-9]|1[0-2])月?)?$",clean(text)).first else { return nil }
        return groups[0] + (Int(groups[1]).map { String(format:".%02d",$0) } ?? "")
    }
    static func isbns(_ text: String) -> [String] {
        // ISBN may wrap after a hyphen, including a final isolated check digit.
        let lines = text.components(separatedBy:.newlines)
        var output: [String] = []
        for (index,line) in lines.enumerated() {
            guard var raw = first("(?:ISBN|IS[BE]N|ISBV|TSBN)\\s*[:：]?\\s*([0-9][0-9Xx \\t－–-]{0,40})",line) ?? (line.trimmingCharacters(in:.whitespaces).uppercased() == "ISBN" ? "" : nil) else { continue }
            var next = index+1
            while next<lines.count && next<=index+2 {
                let digits = raw.filter { $0.isNumber || $0 == "X" || $0 == "x" }
                if digits.count>=13 { break }
                let continuation = lines[next].trimmingCharacters(in:.whitespaces)
                guard continuation.range(of:"^[0-9Xx－– -]+$",options:.regularExpression) != nil else { break }
                raw += continuation; next += 1
            }
            let digits = raw.filter { $0.isNumber || $0 == "X" || $0 == "x" }.uppercased()
            if CopyrightMetadata.validISBN(digits) { output.append(digits) }
        }
        return output
    }
    static func labels(_ lines: [String]) -> [String:String] {
        var result: [String:String] = [:]
        let patterns: [(String,String)] = [
            ("书名","书\\s*名"),("作者","(?:作\\s*者|著\\s*者|编\\s*著|著\\s*译\\s*者)"),
            ("丛书名","(?:丛\\s*书\\s*名|丛\\s*书)"),("出版社","(?:出\\s*版\\s*社|出版发行|出版者)"),
            ("出版日期","(?:出版日期|出版时间)"),("页数","(?:总页数|页数)"),
            ("SS号","(?:SS\\s*号|SSID)"),("DX号","(?:DX\\s*号|DXID)"),
            ("摘要","(?:摘要|内容提要|内容简介)")]
        func production(_ line: String) -> Bool { line.range(of:"^(?:责任编辑|责任校对|装帧设计|封面设计|版式设计|印刷|定价|开本|字数|电话|地址|书号|ISBN|.*第.*[版印])",options:.regularExpression) != nil }
        for (index,line) in lines.enumerated() {
            for (key,label) in patterns where result[key] == nil {
                var value = first("^(?:"+label+")[ \\t:：=]+(.+)$",line)
                if value == nil,line.range(of:"^(?:"+label+")[ \\t:：=]*$",options:.regularExpression) != nil,index+1<lines.count,!production(lines[index+1]) { value = lines[index+1] }
                if let value,!production(value) { result[key] = clean(value) }
            }
        }
        // Explicit bibliographic dates only, not an arbitrary year elsewhere in the imprint.
        if let value = result["出版日期"] { result["出版日期"] = validDate(value) }
        for key in ["页数","SS号","DX号"] {
            if let value = result[key] { result[key] = first("^([0-9]{1,20})(?:\\s*页)?$",value) }
        }
        return result
    }
    static func analyse(_ text: String) -> BibliographicAnalysis {
        let normalized = normalize(text)
        let lines = normalized.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
        var cipLines: [String] = [], outside: [String] = [], notes: [String] = []
        var inside = false, sawHeader = false, sawISBN = false, access = false, hasEnd = false
        for line in lines {
            let compact = line.replacingOccurrences(of:"\\s+",with:"",options:.regularExpression)
            if compact.contains("图书在版编目") || compact.range(of:"^[(（]?CIP[)）]?数据",options:.regularExpression) != nil {
                if sawHeader { notes.append("识别到多段CIP，需核对卷册或合订关系") }
                inside = true; sawHeader = true; sawISBN = false; access = false; continue
            }
            if inside {
                // Both old numeric and new mixed alphanumeric registration identifiers end the CIP block.
                if (compact.contains("核字") || compact.contains("核學") || compact.contains("核学")) && (compact.contains("CIP") || compact.contains("版本")) {
                    inside = false; hasEnd = true; continue
                }
                if compact.range(of:"^(?:[ⅠⅡⅢⅣIVX]+|[1-4])[.、．]",options:.regularExpression) != nil && sawISBN { access = true; continue }
                let imprintStart = line.range(of:"^(?:书\\s*名|作\\s*者|著\\s*者|出版发行|出版者|责任编辑|责任校对|装帧设计|封面设计|版式设计|开本|字数|印刷|出版日期|出版时间|SS号|SSID|DX号|DXID|内容提要|摘要)(?:[ \\t:：=]|$)",options:.regularExpression) != nil || line.range(of:"[12][0-9]{3}年.*第.*[版印]",options:.regularExpression) != nil
                if sawISBN && imprintStart { inside = false; outside.append(line); continue }
                if !access { cipLines.append(line); if compact.range(of:"(?:ISBN|ISEN|ISBV|TSBN)",options:.regularExpression) != nil { sawISBN = true } }
            } else { outside.append(line) }
        }
        if sawHeader && !hasEnd { notes.append("CIP结束标记未确认，请核对区域边界") }
        let cip = cipLines.joined(separator:" ").replacingOccurrences(of:"(?<=[\\p{Han}0-9])\\s+(?=[\\p{Han}0-9])",with:"",options:.regularExpression)
        // Remove only OCR line-wrap spaces, preserving Latin word boundaries.
        var cv: [String:String] = [:]
        if sawHeader {
            let description = cip.components(separatedBy:"ISBN").first ?? cip
            let publication = try? NSRegularExpression(pattern:"([\\p{Han}A-Za-z·]{2,20})\\s*[:：]\\s*([^,，/／—－=]{2,100})\\s*[,，]\\s*([12][0-9]{3})(?:\\s*[.年/-]\\s*(0?[1-9]|1[0-2])(?=[^0-9]|$)月?)?")
            if let match = publication?.firstMatch(in:description,range:NSRange(description.startIndex...,in:description)) {
                let src = description as NSString, placeStart = match.range.location
                let pub = clean(src.substring(with:match.range(at:2))).replacingOccurrences(of:"\\s+(?=[\\p{Han}])",with:"",options:.regularExpression)
                if !pub.isEmpty { cv["出版社"] = pub }
                let year = src.substring(with:match.range(at:3)), month = match.range(at:4).location == NSNotFound ? nil : Int(src.substring(with:match.range(at:4)))
                cv["出版日期"] = year+(month.map { String(format:".%02d",$0) } ?? "")
                var before = clean(src.substring(to:placeStart))
                // Edition area is separate from the responsibility statement.
                before = before.replacingOccurrences(of:"[.。]\\s*[—－-]+\\s*(?:[0-9一二三四五六七八九十]+版|修订版|增订版|重印本)[\\s\\S]*$",with:"",options:.regularExpression)
                let pieces = before.components(separatedBy:CharacterSet(charactersIn:"/／"))
                if let title = pieces.first,!clean(title).isEmpty { cv["书名"] = clean(title) }
                if pieces.count == 2 { cv["作者"] = clean(pieces[1]) }
                else if pieces.count>2 { notes.append("CIP含多个责任说明或合订作品，需逐项核对书名与作者") }
                let afterIndex = match.range.location+match.range.length
                let after = src.substring(from:afterIndex)
                let series = BookMetadata.captures("[（(]([^()（）]+)[)）]",after).compactMap(\.first).filter { !$0.contains("重印") && !$0.contains("ISBN") && !$0.contains("精装") && !$0.contains("平装") }
                if let firstSeries = series.first {
                    let name = firstSeries.components(separatedBy:CharacterSet(charactersIn:"/／;；")).first ?? firstSeries
                    cv["丛书名"] = clean(name)
                    if series.count>1 { notes.append("CIP含多个丛书项，请选择命名采用的丛书") }
                }
                if let pages = first("(?:^|[.。—－ -])([1-9][0-9]{0,4})\\s*页(?:[ :：;；.。]|$)",after) { cv["页数"] = pages }
            } else { notes.append("CIP出版项未完整解析，书名与责任说明未自动截取") }
            if let isbn = isbns(cipLines.joined(separator:"\n")).first { cv["ISBN"] = isbn }
            if isbns(cipLines.joined(separator:"\n")).count>1 { notes.append("CIP有多个ISBN，请核对分册与套装关系") }
        }
        var iv = labels(outside)
        if let isbn = isbns(outside.joined(separator:"\n")).first { iv["ISBN"] = isbn }
        if iv["出版社"] == nil { iv["出版社"] = outside.first { $0.range(of:"^[\\p{Han}A-Za-z·]{2,40}(?:出版社|書局|书局|出版公司)$",options:.regularExpression) != nil } }
        // A first/current edition date is useful; a printing date is not a publication date.
        let editions = BookMetadata.captures("([12][0-9]{3})\\s*年\\s*(0?[1-9]|1[0-2])\\s*月\\s*第\\s*([0-9]+|一|二|三|四|五|六|七|八|九|十)\\s*版",outside.joined(separator:" "))
        if iv["出版日期"] == nil,let edition = editions.last,let month = Int(edition[1]) { iv["出版日期"] = edition[0]+String(format:".%02d",month) }
        if iv["页数"] == nil { iv["页数"] = outside.compactMap { first("^([1-9][0-9]{0,4})\\s*页$",$0) }.first }
        if iv["丛书名"] == nil { iv["丛书名"] = outside.first { $0.range(of:"^[\\p{Han}A-Za-z·]{2,50}(?:丛书|文库|书系)$",options:.regularExpression) != nil } }
        // Keep contradictory sources separate even though only one suggestion can fill a field.
        var values = cv
        for (key,value) in iv where values[key] == nil || key == "作者" { values[key] = value }
        if let date = cv["出版日期"],date.count == 4,let detail = iv["出版日期"],detail.hasPrefix(date+".") { values["出版日期"] = detail }
        var evidence: [BibliographicValue] = []
        for key in BookMetadata.fields {
            if let value = cv[key],!value.isEmpty { evidence.append(.init(field:key,value:value,source:"CIP著录")) }
            if let value = iv[key],!value.isEmpty { evidence.append(.init(field:key,value:value,source:"出版信息")) }
        }
        if sawHeader && cv["ISBN"] == nil { notes.append("CIP的ISBN未通过完整校验，请核对识别文字") }
        return BibliographicAnalysis(values:values,evidence:evidence,notes:Array(Set(notes)).sorted())
    }
}

/// A second, enlarged reading of the small CIP block improves scan OCR without changing the image.
/// It replaces the same region's first pass, so two OCR passes never count as two independent sources.
enum BibliographicOCR {
    static func lines(_ image: CGImage) throws -> [PageInspection.EvidenceLine] {
        let full = try PageInspection.lines(image)
        let sorted = full.sorted { $0.box.midY > $1.box.midY }
        guard let header = sorted.first(where:{ BibliographicExtraction.normalize($0.text).contains("图书在版编目") }),
              let end = sorted.first(where:{$0.box.midY<header.box.midY && $0.text.contains("核") && ($0.text.contains("CIP") || $0.text.contains("版本"))}) else { return sorted }
        let top = min(1,header.box.maxY+0.012),bottom = max(0,end.box.minY-0.012)
        guard top-bottom>0.05 else { return sorted }
        let bounds = CGRect(x:0,y:CGFloat(image.height)*(1-top),width:CGFloat(image.width),height:CGFloat(image.height)*(top-bottom)).integral
        guard let crop = image.cropping(to:bounds) else { return sorted }
        let scale = max(1,min(2.5,2200/CGFloat(crop.width)))
        guard let context = CGContext(data:nil,width:Int(CGFloat(crop.width)*scale),height:Int(CGFloat(crop.height)*scale),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { return sorted }
        context.interpolationQuality = .high; context.draw(crop,in:CGRect(x:0,y:0,width:context.width,height:context.height))
        guard let enlarged = context.makeImage(),let focus = try? PageInspection.lines(enlarged),!focus.isEmpty else { return sorted }
        let mapped = focus.map { line in PageInspection.EvidenceLine(text:line.text,box:CGRect(x:line.box.minX,y:bottom+line.box.minY*(top-bottom),width:line.box.width,height:line.box.height*(top-bottom)),confidence:line.confidence) }
        // Keep the original if the focused pass lost the block header or a previously valid ISBN.
        let before = sorted.filter { $0.box.midY>=bottom && $0.box.midY<=top }.map(\.text).joined(separator:"\n")
        let after = mapped.map(\.text).joined(separator:"\n")
        guard BibliographicExtraction.normalize(after).contains("图书在版编目"),BibliographicExtraction.isbns(before).isEmpty || !BibliographicExtraction.isbns(after).isEmpty else { return sorted }
        return (sorted.filter {$0.box.midY<bottom || $0.box.midY>top}+mapped).sorted {$0.box.midY>$1.box.midY}
    }
}
