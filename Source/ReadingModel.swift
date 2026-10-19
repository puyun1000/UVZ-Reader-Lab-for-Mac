import AppKit

struct ReadingState: Codable {
    var page = 0
    var fraction = 0.0
    var continuous = false
    var doublePages = false
    var rightToLeft = false
    var coverAlone = true
    var wheelTurnsPages = true
    var fit = 0
    var zoom = 1.0
    var color = 0
    var rotation = 0
    var crop = 0.0
    init() {}
    enum CodingKeys: String, CodingKey { case page, fraction, continuous, doublePages, rightToLeft, coverAlone, wheelTurnsPages, fit, zoom, color, rotation, crop }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 0
        fraction = try c.decodeIfPresent(Double.self, forKey: .fraction) ?? 0
        continuous = try c.decodeIfPresent(Bool.self, forKey: .continuous) ?? false
        doublePages = try c.decodeIfPresent(Bool.self, forKey: .doublePages) ?? false
        rightToLeft = try c.decodeIfPresent(Bool.self, forKey: .rightToLeft) ?? false
        coverAlone = try c.decodeIfPresent(Bool.self, forKey: .coverAlone) ?? true
        wheelTurnsPages = try c.decodeIfPresent(Bool.self, forKey: .wheelTurnsPages) ?? true
        fit = try c.decodeIfPresent(Int.self, forKey: .fit) ?? 0
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        color = try c.decodeIfPresent(Int.self, forKey: .color) ?? 0
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        crop = try c.decodeIfPresent(Double.self, forKey: .crop) ?? 0
        page = max(0, page); fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        fit = min(3, max(0, fit)); color = min(2, max(0, color))
        zoom = zoom.isFinite ? min(4, max(0.25, zoom)) : 1
        crop = crop.isFinite ? min(0.15, max(0, crop)) : 0
        rotation = (rotation % 4 + 4) % 4
    }
}

final class NavigationNode: NSObject {
    let title: String
    let page: Int?
    var children: [NavigationNode] = []
    weak var parent: NavigationNode?
    init(_ title: String, page: Int? = nil) { self.title = title; self.page = page }
    func append(_ child: NavigationNode) { child.parent = self; children.append(child) }
}

func navigationNodes(for book: BookArchive, includePages: Bool) -> [NavigationNode] {
    var roots: [NavigationNode] = []
    for (group, title) in ["封面", "书名", "版权", "前言", "目录"].enumerated() {
        if let page = book.pages.firstIndex(where: { $0.key.group == group }) {
            roots.append(NavigationNode(title, page: page))
        }
    }
    if !book.chapters.isEmpty {
        var levels: [(Int, NavigationNode)] = []
        var paths: [String: NavigationNode] = [:]
        for chapter in book.chapters {
            let node = NavigationNode(chapter.title, page: chapter.pageIndex < 0 ? nil : chapter.pageIndex)
            var parent: NavigationNode?
            if let path = chapter.path, path.count > 2 {
                for length in stride(from: path.count - 2, through: 2, by: -2) {
                    if let found = paths[String(path.prefix(length))] { parent = found; break }
                }
            }
            while let last = levels.last, last.0 >= chapter.level { levels.removeLast() }
            if parent == nil, chapter.level > 0 { parent = levels.last?.1 }
            if let parent { parent.append(node) } else { roots.append(node) }
            if let path = chapter.path { paths[path] = node }
            levels.append((chapter.level, node))
        }
    }
    if includePages {
        let all = NavigationNode("页码")
        for (index, page) in book.pages.enumerated() {
            all.append(NavigationNode("\(index + 1) · \(page.label)", page: index))
        }
        roots.append(all)
    }
    return roots
}

struct ReadingLayout {
    var frames: [Int: CGRect] = [:]
    var size: CGSize = .zero
    var rows: [(indices: [Int], frame: CGRect)] = []
    static func spreads(count: Int, state: ReadingState) -> [[Int]] {
        guard count > 0 else { return [] }
        if !state.doublePages { return (0..<count).map { [$0] } }
        var result: [[Int]] = [], index = 0
        if state.coverAlone { result.append([0]); index = 1 }
        while index < count { result.append(Array(index..<min(count, index + 2))); index += 2 }
        return result
    }
    static func spread(containing page: Int, count: Int, state: ReadingState) -> [Int] {
        guard count > 0 else { return [] }
        let page = min(count - 1, max(0, page))
        if !state.doublePages || (state.coverAlone && page == 0) { return [page] }
        let offset = state.coverAlone ? 1 : 0
        let start = offset + ((page - offset) / 2) * 2
        return Array(start..<min(count, start + 2))
    }
    static func destination(from page: Int, direction: Int, count: Int, state: ReadingState) -> Int {
        guard count > 0 else { return 0 }
        let page = min(count - 1, max(0, page))
        if !state.doublePages { return min(count - 1, max(0, page + direction)) }
        let group = spread(containing: page, count: count, state: state), first = group[0]
        if direction > 0 { let next = first + group.count; return next < count ? next : page }
        return first == 0 ? page : max(0, first - 2)
    }
    static func make(sizes: [CGSize], viewport: CGSize, state: ReadingState) -> ReadingLayout {
        var result = ReadingLayout()
        let width = max(160, viewport.width), height = max(160, viewport.height), margin: CGFloat = 20, gap: CGFloat = 16
        let transformed = sizes.map { size -> CGSize in
            let f = 1 - state.crop * 2
            let value = CGSize(width: max(1, size.width * f), height: max(1, size.height * f))
            return state.rotation % 2 == 0 ? value : CGSize(width: value.height, height: value.width)
        }
        guard !sizes.isEmpty else { result.size = CGSize(width: width, height: height); return result }
        let visible = state.continuous ? spreads(count: sizes.count, state: state) : [spread(containing: state.page, count: sizes.count, state: state)]
        var specifications: [(indices: [Int], factor: CGFloat, width: CGFloat, height: CGFloat)] = []
        for indices in visible {
            let gutter = indices.count > 1 ? gap : 0
            let row = CGSize(width: indices.reduce(0) { $0 + transformed[$1].width }, height: indices.map { transformed[$0].height }.max() ?? 1)
            let available = CGSize(width: max(1, width - margin * 2 - gutter), height: max(1, height - margin * 2))
            let base: CGFloat
            switch state.fit {
            case 1: base = min(available.width / row.width, available.height / row.height)
            case 2: base = available.height / row.height
            case 3: base = 1
            default: base = available.width / row.width
            }
            let factor = max(0.01, base * state.zoom)
            specifications.append((indices, factor, row.width * factor + gutter, row.height * factor))
        }
        let documentWidth = max(width, (specifications.map(\.width).max() ?? 0) + margin * 2)
        var y = margin
        let singleHeight = max(height, (specifications.first?.height ?? 0) + margin * 2)
        for row in specifications {
            let top = state.continuous ? y : (singleHeight - row.height) / 2
            let indices = state.rightToLeft ? row.indices.reversed().map { $0 } : row.indices
            var x = (documentWidth - row.width) / 2
            for index in indices {
                let size = transformed[index], h = size.height * row.factor, w = size.width * row.factor
                result.frames[index] = CGRect(x: x, y: top + (row.height - h) / 2, width: w, height: h)
                x += w + gap
            }
            result.rows.append((row.indices, CGRect(x: (documentWidth - row.width) / 2, y: top, width: row.width, height: row.height)))
            y = top + row.height + gap
        }
        result.size = CGSize(width: documentWidth, height: state.continuous ? max(height, y - gap + margin) : singleHeight)
        return result
    }
    func page(at y: CGFloat) -> Int? {
        (rows.last { $0.frame.minY <= y + 24 } ?? rows.first)?.indices.first
    }
    func anchor(for page: Int) -> CGRect? { rows.first { $0.indices.contains(page) }?.frame }
    func fraction(page: Int, y: CGFloat) -> Double {
        guard let frame = anchor(for: page) else { return 0 }
        return min(1, max(0, (y - frame.minY) / max(1, frame.height)))
    }
}
