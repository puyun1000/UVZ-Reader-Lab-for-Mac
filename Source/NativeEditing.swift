import AppKit

/// On-device transformations; replacements go through the text system and support Undo.
enum TextConversion {
    static let titles = ["转为简体中文","转为繁体中文","转为半角","转为全角","转为大写","转为小写","词首字母大写","改用中文标点","改用英文标点"]
    static func apply(_ text:String,_ kind:Int)->String {
        switch kind {
        case 0:return text.applyingTransform(.init("Traditional-Simplified"),reverse:false) ?? text
        case 1:return text.applyingTransform(.init("Simplified-Traditional"),reverse:false) ?? text
        case 2:return text.applyingTransform(.fullwidthToHalfwidth,reverse:false) ?? text
        case 3:return text.applyingTransform(.fullwidthToHalfwidth,reverse:true) ?? text
        case 4:return text.uppercased()
        case 5:return text.lowercased()
        case 6:return text.capitalized
        case 7:
            var result=text
            let han="[\\p{Han}，。；：！？、）》」』】]"
            for (from,to) in [(",","，"),(":","："),(";","；"),("?","？"),("!","！")] {
                let escaped=NSRegularExpression.escapedPattern(for:from)
                for pattern in ["(?<=\(han))\(escaped)","\(escaped)(?=[ \\t]*[\\p{Han}])"] {
                    if let regex=try? NSRegularExpression(pattern:pattern) {result=regex.stringByReplacingMatches(in:result,range:NSRange(location:0,length:(result as NSString).length),withTemplate:to)}
                }
            }
            for (pattern,replacement) in [("\"([^\"\\n]*\\p{Han}[^\"\\n]*)\"","“$1”"),("'([^'\\n]*\\p{Han}[^'\\n]*)'","‘$1’")] {
                if let regex=try? NSRegularExpression(pattern:pattern) {result=regex.stringByReplacingMatches(in:result,range:NSRange(location:0,length:(result as NSString).length),withTemplate:replacement)}
            }
            return result
        case 8:
            return text.reduce(into:"") {out,ch in out += ["，":",","：":":","；":";","？":"?","！":"!","。":".","（":"(","）":")","“":"\"","”":"\"","‘":"'","’":"'","【":"[","】":"]"][String(ch)] ?? String(ch)}
        default:return text
        }
    }
    static func menu(target:AnyObject?,action:Selector,copy:Bool=false)->NSMenu {
        let menu=NSMenu(title:copy ? "转换后复制" : "文字转换")
        for (index,title) in titles.enumerated() {
            if [2,4,7].contains(index) {menu.addItem(.separator())}
            let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.tag=index;item.target=target;menu.addItem(item)
        }
        return menu
    }
    static func button(for text:ChineseTextView)->NSPopUpButton {
        let button=NSPopUpButton(frame:.zero,pullsDown:true);button.bezelStyle = .rounded
        let menu=NSMenu();menu.addItem(withTitle:"文字转换",action:nil,keyEquivalent:"")
        for item in self.menu(target:text,action:#selector(ChineseTextView.convertSelection)).items {menu.addItem(item.copy() as! NSMenuItem)}
        button.menu=menu;button.toolTip="先选中文字；繁简、全半角、大小写与标点转换均可撤销";return button
    }
}

class ChineseTextView:NSTextView {
    @objc func convertSelection(_ sender:NSMenuItem) {
        let range=selectedRange();guard range.length>0,NSMaxRange(range)<=(string as NSString).length else {NSSound.beep();return}
        let transformed=TextConversion.apply((string as NSString).substring(with:range),sender.tag)
        if isEditable {
            breakUndoCoalescing();insertText(transformed,replacementRange:range);setSelectedRange(NSRange(location:range.location,length:(transformed as NSString).length));breakUndoCoalescing()
        } else {NSPasteboard.general.clearContents();NSPasteboard.general.setString(transformed,forType:.string)}
    }
    override func validateMenuItem(_ item:NSMenuItem)->Bool {
        if item.action == #selector(undoText) {return isEditable && undoManager?.canUndo == true}
        if item.action == #selector(redoText) {return isEditable && undoManager?.canRedo == true}
        if item.action == #selector(convertSelection) {return selectedRange().length>0 && isSelectable}
        return super.validateMenuItem(item)
    }
    override func menu(for event:NSEvent)->NSMenu? {chineseMenu()}
    func chineseMenu()->NSMenu {
        let menu=NSMenu(title:"文字操作")
        func add(_ title:String,_ selector:Selector,_ enabled:Bool=true) {let item=NSMenuItem(title:title,action:selector,keyEquivalent:"");item.target=self;item.isEnabled=enabled;menu.addItem(item)}
        if isEditable {add("撤销",#selector(undoText),undoManager?.canUndo == true);add("重做",#selector(redoText),undoManager?.canRedo == true);menu.addItem(.separator());add("剪切",#selector(cut(_:)),selectedRange().length>0)}
        add("复制",#selector(copy(_:)),selectedRange().length>0)
        if isEditable {add("粘贴",#selector(paste(_:)));add("粘贴并匹配样式",#selector(pasteAsPlainText(_:)));add("删除",#selector(delete(_:)),selectedRange().length>0)}
        add("全选",#selector(selectAll(_:)));menu.addItem(.separator())
        let conversion=NSMenuItem(title:isEditable ? "文字转换" : "转换后复制",action:nil,keyEquivalent:"");conversion.submenu=TextConversion.menu(target:self,action:#selector(convertSelection),copy:!isEditable);menu.addItem(conversion)
        return menu
    }
    @objc private func undoText() {undoManager?.undo()}
    @objc private func redoText() {undoManager?.redo()}
}
/// Single-line values align with their surrounding native controls at any
/// control height. Wrapping labels and multiline editors keep their own layout.
final class CenteredTextFieldCell:NSTextFieldCell {
    override func drawingRect(forBounds rect:NSRect) -> NSRect {
        var interior=super.drawingRect(forBounds:rect)
        guard isScrollable || usesSingleLineMode || !wraps else {return interior}
        let font=self.font ?? .systemFont(ofSize:NSFont.systemFontSize)
        let height=ceil(font.ascender-font.descender+font.leading)
        interior.origin.y += max(0,(interior.height-height)/2)
        interior.size.height=min(interior.height,height)
        return interior
    }
    override func edit(withFrame rect:NSRect,in view:NSView,editor:NSText,delegate:Any?,event:NSEvent?) {
        super.edit(withFrame:drawingRect(forBounds:rect),in:view,editor:editor,delegate:delegate,event:event)
    }
    override func select(withFrame rect:NSRect,in view:NSView,editor:NSText,delegate:Any?,start:Int,length:Int) {
        super.select(withFrame:drawingRect(forBounds:rect),in:view,editor:editor,delegate:delegate,start:start,length:length)
    }
}
class CenteredTextField:NSTextField {
    override class var cellClass:AnyClass? {
        get {CenteredTextFieldCell.self}
        set {}
    }
}
class ChineseWindow:NSWindow {
    private var chineseEditor:ChineseTextView?
    override func fieldEditor(_ createFlag:Bool,for object:Any?)->NSText? {
        guard object == nil || (object is NSTextField && !(object is NSSecureTextField)) else{return super.fieldEditor(createFlag,for:object)}
        if chineseEditor == nil,createFlag {let text=ChineseTextView();text.isFieldEditor=true;text.allowsUndo=true;chineseEditor=text}
        return chineseEditor
    }
}
class ChinesePanel:NSPanel {
    private var chineseEditor:ChineseTextView?
    override func fieldEditor(_ createFlag:Bool,for object:Any?)->NSText? {
        guard object == nil || (object is NSTextField && !(object is NSSecureTextField)) else{return super.fieldEditor(createFlag,for:object)}
        if chineseEditor == nil,createFlag {let text=ChineseTextView();text.isFieldEditor=true;text.allowsUndo=true;chineseEditor=text}
        return chineseEditor
    }
}

/// Preserve system Live Text actions while presenting their menus in Chinese.
enum ChineseMenus {
    private static var observer:NSObjectProtocol?
    static func install() {
        guard observer == nil else{return}
        observer=NotificationCenter.default.addObserver(forName:NSMenu.didBeginTrackingNotification,object:nil,queue:.main) {notification in if let menu=notification.object as? NSMenu {localize(menu)}}
    }
    static func localize(_ menu:NSMenu) {
        let names=["Copy":"复制","Copy Text":"复制文字","Copy All Text":"复制全部文字","Select Text":"选择文字","Show Text":"显示文字","Hide Text":"隐藏文字","Visual Look Up":"图像查询","Quick Note":"快速备忘录","Copy Subject":"复制主体","Cut":"剪切","Paste":"粘贴","Paste and Match Style":"粘贴并匹配样式","Select All":"全选","Delete":"删除","Undo":"撤销","Redo":"重做","Look Up":"查询","Translate":"翻译","Search the Web":"搜索网页","Search with Google":"使用Google搜索","Copy Image":"复制图像","Save Image As…":"图像另存为…","Share":"共享","Services":"服务","Transformations":"文字转换","Make Upper Case":"转为大写","Make Lower Case":"转为小写","Capitalize":"词首字母大写","Spelling and Grammar":"拼写和语法","Substitutions":"文本替换","Speech":"朗读","Start Speaking":"开始朗读","Stop Speaking":"停止朗读","Writing Tools":"写作工具","Show Spelling and Grammar":"显示拼写和语法","Check Document Now":"立即检查文稿","Check Spelling While Typing":"键入时检查拼写","Check Grammar With Spelling":"检查语法","Correct Spelling Automatically":"自动改正拼写","Smart Quotes":"智能引号","Smart Dashes":"智能破折号","Smart Links":"智能链接","Data Detectors":"数据检测","Text Replacement":"文本替换","Show Substitutions":"显示文本替换","Open Link":"打开链接","Copy Link":"复制链接"]
        for item in menu.items {
            if let title=names[item.title] {item.title=title}
            else if item.title.hasPrefix("Look Up ") {item.title="查询 "+item.title.dropFirst(8)}
            else if item.title.hasPrefix("Translate ") {item.title="翻译 "+item.title.dropFirst(10)}
            if let submenu=item.submenu {localize(submenu)}
        }
    }
}
