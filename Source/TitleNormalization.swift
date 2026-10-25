import Foundation

struct TitleNormalizationResult {
    var values: [String:String]
    var reasons: [String:String] = [:]
    var ambiguous = false
}
enum TitleNormalization {
    /// Bibliographic suggestions only. Manual edits are never overridden by these rules.
    static func apply(_ input: [String:String],locked: Set<String> = []) -> TitleNormalizationResult {
        var result = TitleNormalizationResult(values:input)
        guard !locked.contains("书名"),var title = input["书名"],!title.isEmpty else { return result }
        let original = title
        let japanese = title.range(of:"[\\p{Hiragana}\\p{Katakana}]",options:.regularExpression) != nil
        guard !japanese,title.range(of:"\\p{Han}",options:.regularExpression) != nil else { return result }
        let seriesSuffix = "(?:丛书|叢書|文库|文庫|论丛|論叢|文丛|文叢|大系|系列|书系|書系|叢刊|丛刊)"
        if !locked.contains("丛书名"),input["丛书名",default:""].trimmingCharacters(in:.whitespaces).isEmpty {
            let patterns = ["^[【\\[（(]([^】\\]）)]{2,40}"+seriesSuffix+")[】\\]）)]\\s*(.{2,})$","^([^\\s：:【】]{2,30}"+seriesSuffix+")[ \\t:：]+(.{2,})$"]
            for pattern in patterns {
                if let match = BookMetadata.captures(pattern,title).first,match.count == 2 {
                    result.values["丛书名"] = match[0];title = match[1];result.reasons["丛书名"] = "从书名前的丛书标识移入"; break
                }
            }
        }
        // Only punctuation separating Chinese characters; English phrases and ISBN remain unchanged.
        for (a,b) in [(",","，"),(":","："),(";","；")] {
            title = title.replacingOccurrences(of:"(?<=\\p{Han})\\s*"+NSRegularExpression.escapedPattern(for:a)+"\\s*(?=\\p{Han})",with:b,options:.regularExpression)
        }
        title = title.replacingOccurrences(of:"(?<![（(0-9])\\s+([12][0-9]{3}\\s*[—–－-]{1,2}\\s*[12][0-9]{3})(?![0-9）)])",with:"（$1）",options:.regularExpression)
        let pieces = title.components(separatedBy:.whitespaces).filter {!$0.isEmpty}
        if pieces.count == 2,pieces.allSatisfy({$0.range(of:"^\\p{Han}+$",options:.regularExpression) != nil}) {
            let a = pieces[0],b = pieces[1]
            let combined = a.count<=4 && b.count<=4 || ["与","與","和","及","暨","合订","合訂"].contains(where:{a.hasSuffix($0) || b.hasPrefix($0)})
            if combined { result.ambiguous = true }
            else { title = a+"："+b }
        } else if pieces.count>1,title.range(of:"(?<=\\p{Han})\\s+(?=\\p{Han})",options:.regularExpression) != nil { result.ambiguous = true }
        title = title.trimmingCharacters(in:.whitespacesAndNewlines)
        result.values["书名"] = title
        if title != original { result.reasons["书名"] = "规范中文标点、年代范围或丛书前缀" }
        return result
    }
}
