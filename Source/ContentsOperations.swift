import AppKit

/// Structural edits work on real subtrees, keeping unselected descendants with their parent.
enum ContentsOperations {
    enum Action { case indent, outdent, up, down, delete }
    private final class Node {
        let id: Int
        var value: BookEditDraft.Chapter
        var children: [Node] = []
        weak var parent: Node?
        init(_ id: Int, _ value: BookEditDraft.Chapter) { self.id = id; self.value = value }
    }
    struct Result { var chapters: [BookEditDraft.Chapter]; var selection: IndexSet }
    static func apply(_ action: Action, chapters: [BookEditDraft.Chapter], selected: IndexSet) throws -> Result {
        let root = Node(-1, .init(title: "", page: 0, level: -1))
        var stack = [root], nodes: [Node] = []
        for (index, value) in chapters.enumerated() {
            guard value.level >= 0, value.level <= 32, value.level <= stack.count - 1 else { throw ReaderFailure("请先修正目录层级：首项应为第 1 级，后续项最多加深一级。") }
            while stack.count > value.level + 1 { stack.removeLast() }
            let node = Node(index, value); node.parent = stack.last; stack.last!.children.append(node); nodes.append(node); stack.append(node)
        }
        let valid = selected.filter { chapters.indices.contains($0) }
        let targets = valid.compactMap { index -> Node? in
            var ancestor = nodes[index].parent
            while let parent = ancestor, parent !== root { if selected.contains(parent.id) { return nil }; ancestor = parent.parent }
            return nodes[index]
        }
        guard !targets.isEmpty else { return Result(chapters: chapters, selection: selected) }
        let ids = Set(targets.map(\.id))
        var parents: [Node] = []
        for node in targets { if let parent = node.parent, !parents.contains(where: { $0 === parent }) { parents.append(parent) } }
        if action == .indent {
            for parent in parents {
                guard let first = parent.children.firstIndex(where: { ids.contains($0.id) }), first > 0 else { throw ReaderFailure("同级首项前面没有可作为父项的目录，不能降级；请调整选择范围。") }
            }
            for parent in parents {
                let old = parent.children; var preceding: Node?
                parent.children = []
                for node in old {
                    if ids.contains(node.id), let preceding { node.parent = preceding; preceding.children.append(node) }
                    else { parent.children.append(node); preceding = node }
                }
            }
        } else if action == .outdent {
            guard targets.allSatisfy({ $0.parent !== root }) else { throw ReaderFailure("第 1 级目录不能再升级；请取消选择第 1 级条目。") }
            // Deepest parents first; selected subtrees are disjoint, including collapsed children.
            for parent in parents.sorted(by: { $0.value.level > $1.value.level }) {
                guard let grand = parent.parent, let index = grand.children.firstIndex(where: { $0 === parent }) else { continue }
                let lifted = parent.children.filter { ids.contains($0.id) }
                parent.children.removeAll { ids.contains($0.id) }
                lifted.forEach { $0.parent = grand }; grand.children.insert(contentsOf: lifted, at: index + 1)
            }
        } else if action == .delete {
            for parent in parents { parent.children.removeAll { ids.contains($0.id) } }
        } else {
            for parent in parents {
                if action == .up {
                    for i in parent.children.indices where i > 0 && ids.contains(parent.children[i].id) && !ids.contains(parent.children[i - 1].id) { parent.children.swapAt(i, i - 1) }
                } else if parent.children.count > 1 {
                    for i in stride(from: parent.children.count - 2, through: 0, by: -1) where ids.contains(parent.children[i].id) && !ids.contains(parent.children[i + 1].id) { parent.children.swapAt(i, i + 1) }
                }
            }
        }
        var output: [BookEditDraft.Chapter] = [], selection = IndexSet()
        func flatten(_ parent: Node, _ level: Int) throws {
            for node in parent.children {
                guard level <= 32 else { throw ReaderFailure("目录层级不能超过 33 级；本次操作未应用。") }
                var value = node.value; value.level = level
                if valid.contains(node.id) { selection.insert(output.count) }
                output.append(value); try flatten(node, level + 1)
            }
        }
        try flatten(root, 0)
        return Result(chapters: output, selection: selection)
    }
}

final class ContentsOutlineView: NSOutlineView {
    var performEdit: ((ContentsOperations.Action) -> Void)?
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift { performEdit?(modifiers == .shift ? .outdent : .indent); return }
        if modifiers == .control, event.keyCode == 126 || event.keyCode == 125 { performEdit?(event.keyCode == 126 ? .up : .down); return }
        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 { performEdit?(.delete); return }
        super.keyDown(with: event)
    }
}
