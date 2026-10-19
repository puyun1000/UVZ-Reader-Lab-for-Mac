import Foundation

/// One page map for typed navigation, directory text and the directory tree.
struct PageAddressing {
    static let titles = ["封面", "书名", "版权", "前言", "目录", "正文", "附录", "封底", "其他"]
    static let prefixes = ["cov", "bok", "leg", "fow", "!", "", "att", "bac"]
    let book: BookArchive
    let base: Int
    private let lookup: [String: [Int]]
    init(_ book: BookArchive, base: Int = 1) {
        self.book = book; self.base = base
        lookup = book.pages.indices.reduce(into: [:]) { $0["\(book.pages[$1].key.group):\(book.pages[$1].number)", default: []].append($1) }
    }
    func pages(in group: Int) -> [Int] { group == -1 ? Array(book.pages.indices) : book.pages.indices.filter { book.pages[$0].key.group == group } }
    func number(at index: Int, group: Int) -> Int {
        if group == -1 { return index + 1 }
        if book.usesPDGNumbering { return book.pages[index].number }
        return index + 1 >= base ? index - base + 2 : index + 1 - base
    }
    func range(in group: Int) -> String {
        let values = pages(in: group).map { number(at: $0, group: group) }
        guard let low = values.min(), let high = values.max() else { return "无页面" }
        return low == high ? String(low) : "\(low)—\(high)"
    }
    func rangeDescription(in group: Int) -> String {
        let values = Array(Set(pages(in: group).map { number(at: $0, group: group) })).sorted()
        let gaps = book.usesPDGNumbering && group != -1 && zip(values, values.dropFirst()).contains { $1 > $0 + 1 }
        return range(in: group) + (gaps ? "（含断号）" : "")
    }
    static func normalized(_ text: String) -> String {
        var value = text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".pdg") { value = String(value.dropLast(4)) }
        return value
    }
    static func address(_ raw: String, defaultGroup: Int = 5) throws -> (group: Int, number: Int) {
        let value = normalized(raw)
        if value.hasPrefix("@"), let number = Int(value.dropFirst()) { return (-1, number) }
        for (group, title) in (titles + ["物理页"]).enumerated() where value.hasPrefix(title) {
            let digits = value.dropFirst(title.count).trimmingCharacters(in: .whitespaces)
            if let number = Int(digits) { return (group == 9 ? -1 : group, number) }
        }
        for (group, prefix) in prefixes.enumerated() where !prefix.isEmpty && value.hasPrefix(prefix) {
            if let number = Int(value.dropFirst(prefix.count)) { return (group == 0 && number >= 2 ? 7 : group, number) }
        }
        if let number = Int(value) { return (defaultGroup, number) }
        throw ReaderFailure("页号应为数字、cov／bok／leg／fow／!／att／bac 加数字，或 @加物理页码。")
    }
    func resolve(_ text: String, defaultGroup: Int = 5) throws -> Int {
        let address = try Self.address(text, defaultGroup: defaultGroup)
        if address.group == -1 {
            guard (1...book.pages.count).contains(address.number) else { throw ReaderFailure("物理页码应在 1—\(book.pages.count) 之间。") }
            return address.number
        }
        if !book.usesPDGNumbering {
            guard address.group == 5 else { throw ReaderFailure("此文档没有 PDG 页面类型，请使用正文页号或 @加物理页码。") }
            let number = address.number
            guard number != 0, number > -book.pages.count, number <= book.pages.count else { throw ReaderFailure("请输入有效页号，正文之前使用负数；0 不作为页号。") }
            let physical = number > 0 ? base + number - 1 : base + number
            guard (1...book.pages.count).contains(physical) else { throw ReaderFailure("页号换算后超出文档，请核对正文基准页。") }
            return physical
        }
        let matches = lookup["\(address.group):\(address.number)"] ?? []
        guard matches.count == 1 else {
            if matches.count > 1 { throw ReaderFailure("该页号对应多个页面，请用 @加物理页码明确定位。") }
            let title = Self.titles.indices.contains(address.group) ? Self.titles[address.group] : "当前类型"
            let values = Array(Set(pages(in: address.group).map { book.pages[$0].number })).sorted()
            if let lower = values.last(where: { $0 < address.number }), let upper = values.first(where: { $0 > address.number }) {
                let missing = lower + 1 == upper - 1 ? String(address.number) : "\(lower + 1)—\(upper - 1)"
                throw ReaderFailure("当前文件的\(title)类型未匹配第 \(address.number) 页；该类型在 \(missing) 之间断号，相邻可用页号为 \(lower)、\(upper)。\(title)页号范围：\(rangeDescription(in: address.group))。断号不代表图像缺失，页面可能归入前言、目录等其他类型；请核对后用类型前缀或 @加物理页码定位。暂不跳转的目录项可保留标题并清空页号。")
            }
            throw ReaderFailure("当前文件未找到\(title)第 \(address.number) 页；该类型页号范围：\(rangeDescription(in: address.group))。请核对页面类型，或用 @加物理页码明确指定已有页面。暂不跳转的目录项可保留标题并清空页号。")
        }
        return matches[0] + 1
    }
    func token(_ physical: Int, localGroup: Int? = nil) -> String {
        guard (1...book.pages.count).contains(physical) else { return "" }
        let item = book.pages[physical - 1]
        if !book.usesPDGNumbering { return String(number(at: physical - 1, group: 5)) }
        guard lookup["\(item.key.group):\(item.number)"]?.count == 1, item.key.group < Self.prefixes.count else { return "@\(physical)" }
        return (localGroup == item.key.group ? "" : Self.prefixes[item.key.group]) + String(item.number)
    }
    func canonical(_ raw: String, defaultGroup: Int) -> String {
        let value = Self.normalized(raw)
        guard let address = try? Self.address(value, defaultGroup: defaultGroup), address.group >= 0, address.group < Self.prefixes.count else { return value }
        return Self.prefixes[address.group] + String(address.number)
    }
}
