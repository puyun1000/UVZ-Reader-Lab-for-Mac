import AppKit

/// Text interchange follows PdgCntEditor's TAB indentation and PDG page prefixes.
enum ContentsTextCodec {
    static func category(_ chapter: BookEditDraft.Chapter, book: BookArchive) -> Int {
        if let target = chapter.unresolvedTarget, let address = try? PageAddressing.address(target) { return address.group }
        return chapter.page > 0 && chapter.page <= book.pages.count ? book.pages[chapter.page - 1].key.group : 5
    }
    static func pageToken(_ page: Int, book: BookArchive, base: Int) -> String { PageAddressing(book, base: base).token(page) }
    static func text(_ chapters: [BookEditDraft.Chapter], book: BookArchive, base: Int = 1, localGroup: Int? = nil) -> String {
        let map = PageAddressing(book, base: base)
        return chapters.map { chapter in
            var token = chapter.unresolvedTarget ?? map.token(chapter.page, localGroup: localGroup)
            if let target = chapter.unresolvedTarget, let localGroup, let address = try? PageAddressing.address(target), address.group == localGroup { token = String(address.number) }
            return String(repeating: "\t", count: max(0, min(32, chapter.level))) + chapter.title + "\t" + token
        }.joined(separator: "\n")
    }
    static func chapters(_ text: String, book: BookArchive, base: Int = 1, defaultGroup: Int = 5, allowUnresolved: Bool = false) throws -> [BookEditDraft.Chapter] {
        guard text.utf8.count <= 2 * 1024 * 1024, (1...book.pages.count).contains(base) else { throw ReaderFailure("目录文本过大，或正文基准页超出范围。") }
        let map = PageAddressing(book, base: base)
        var result: [BookEditDraft.Chapter] = []
        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let level = raw.prefix(while: { $0 == "\t" }).count
            let content = String(raw.dropFirst(level)), split = content.lastIndex(of: "\t")
            let title = (split.map { String(content[..<$0]) } ?? content).trimmingCharacters(in: .whitespaces)
            let target = (split.map { String(content[content.index(after: $0)...]) } ?? "").trimmingCharacters(in: .whitespaces)
            func fail(_ message: String) -> ReaderFailure { ReaderFailure("第 \(offset + 1) 行：" + message) }
            guard level <= 32, !title.isEmpty, !title.contains("\t"), !title.contains("|") else { throw fail("标题无效；用行首 TAB 缩进，标题后一个 TAB 分隔页号。") }
            var physical = 0, unresolved: String?
            if !target.isEmpty {
                do { physical = try map.resolve(target, defaultGroup: defaultGroup) }
                catch { if allowUnresolved { unresolved = map.canonical(target, defaultGroup: defaultGroup) } else { throw fail(error.localizedDescription) } }
            }
            result.append(.init(title: title, page: physical, level: level, unresolvedTarget: unresolved))
            guard result.count <= 50_000 else { throw fail("目录项超过限制。") }
        }
        return result
    }
    static func splitTrailingNumbers(_ text: String) -> String {
        let expression = try! NSRegularExpression(pattern: "^(\\t*)(.+?) +((?:cov|bok|leg|fow|!|att|bac|@)?-?[0-9]+) *$", options: .caseInsensitive)
        return text.components(separatedBy: .newlines).map { line in
            if line.drop(while: { $0 == "\t" }).contains("\t") { return line }
            return expression.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "$1$2\t$3")
        }.joined(separator: "\n")
    }
}

final class ContentsTextView: ChineseTextView {
    override func insertTab(_ sender: Any?) {
        if selectedRange().length > 0 { shiftIndent(1) }
        else { insertText("\t", replacementRange: selectedRange()) }
    }
    override func insertBacktab(_ sender: Any?) { shiftIndent(-1) }
    override func insertNewline(_ sender: Any?) {
        let value = string as NSString, caret = min(selectedRange().location, value.length)
        let line = value.lineRange(for: NSRange(location: caret, length: 0))
        let prefix = (value.substring(with: NSRange(location: line.location, length: max(0, caret - line.location)))).prefix { $0 == "\t" }
        insertText("\n" + prefix, replacementRange: selectedRange())
    }
    func shiftIndent(_ delta: Int) {
        let text = string as NSString, selection = selectedRange()
        let range = text.lineRange(for: NSRange(location: selection.location, length: max(0, selection.length - (selection.length > 0 ? 1 : 0))))
        let old = text.substring(with: range), trailing = old.hasSuffix("\n")
        var lines = old.components(separatedBy: "\n")
        if trailing { lines.removeLast() }
        let updated = lines.map { delta > 0 ? "\t" + $0 : ($0.hasPrefix("\t") ? String($0.dropFirst()) : $0) }.joined(separator: "\n") + (trailing ? "\n" : "")
        insertText(updated, replacementRange: range)
        setSelectedRange(NSRange(location: range.location, length: (updated as NSString).length))
    }
}

final class EditorTreeNode: NSObject {
    let index: Int
    var children: [EditorTreeNode] = []
    init(_ index: Int) { self.index = index }
}

struct FilenameDraft {
    var title: String, author: String, publisher: String, year: String, ss: String
    var metadata: [String: String] = [:]
    init(book: BookArchive) {
        let source = BookMetadata.canonical(book.metadata)
        metadata = source
        let explicitTitle = source["书名"].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        title = explicitTitle ?? book.title
        author = source["作者"] ?? ""; publisher = source["出版社"] ?? ""
        let date = source["出版日期"] ?? ""
        year = BookMetadata.date(date)
        ss = source["SS号"] ?? ""
        if ss.isEmpty, let range = book.url.deletingPathExtension().lastPathComponent.range(of: "[0-9]{8}$", options: .regularExpression) { ss = String(book.url.deletingPathExtension().lastPathComponent[range]) }
        if explicitTitle == nil, !ss.isEmpty, title.hasSuffix(ss) {
            let stripped = String(title.dropLast(ss.count)).trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
            if !stripped.isEmpty { title = stripped }
        }
    }
    var values: [String: String] { var values = BookMetadata.canonical(metadata); values["书名"] = title; values["作者"] = author; values["出版社"] = publisher; values["出版日期"] = year; values["SS号"] = ss; return values }
    static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "[/:\\x00-\\x1f]", with: "－", options: .regularExpression)
    }
    func name(style: Int) -> String {
        (try? FilenameTemplate.render(FilenameTemplate.presets[min(FilenameTemplate.presets.count - 1, max(0, style))], metadata: values)) ?? ""
    }
}
