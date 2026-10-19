import AppKit

final class DialogTestDelegate: NSObject, NSApplicationDelegate {
    let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    var checks: [String] = []
    var panel: NSOpenPanel?
    func check(_ value: Bool, _ title: String) { if !value { fputs("DIALOG_FAILED \(title)\n", stderr); exit(1) }; checks.append(title) }
    func applicationDidFinishLaunching(_ note: Notification) {
        parent.makeKeyAndOrderFront(nil)
        let child = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 450,height: 300),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        child.isReleasedWhenClosed = false; NativeDialog.present(child,on:parent)
        let frame = parent.frame, old = child.frame.origin
        child.setFrameOrigin(NSPoint(x: old.x+20,y: old.y+20))
        check(child.isMovable && child.sheetParent == nil && child.frame.origin != old && parent.frame == frame && parent.hasDocumentDialog,"原生标题栏窗口独立移动且父窗口不随动")
        NativeDialog.dismiss(child)
        check(!child.isVisible && child.parent == nil && !parent.hasDocumentDialog,"关闭弹窗正确解除所属关系")
        let alert = NSAlert();alert.messageText = "测试提示框";alert.addButton(withTitle:"确定");alert.addButton(withTitle:"取消")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2){
            self.check(alert.window.isMovable && alert.window.isMovableByWindowBackground && alert.window.sheetParent == nil,"系统提示框可从背景拖移")
            NSApplication.shared.stopModal(withCode:.alertSecondButtonReturn)
        }
        NativeDialog.alert(alert,on:parent){response in
            self.check(response == .alertSecondButtonReturn,"系统提示框关闭和返回结果正确")
        }
        let open = NSOpenPanel();panel = open;open.directoryURL = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true);open.isMovable = true
        open.begin { response in
            self.check(response == .cancel,"系统文件面板取消不改变图书")
            let report:[String:Any] = ["passed":self.checks.count,"checks":self.checks]
            let data = try! JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);FileHandle.standardOutput.write(data);exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.7){self.check(open.isMovable && open.sheetParent == nil,"系统文件面板可独立拖移");open.cancel(nil)}
    }
}
@main enum NativeDialogTestMain {
    static func main() {let app = NSApplication.shared, delegate = DialogTestDelegate();app.setActivationPolicy(.accessory);app.delegate = delegate;app.run()}
}
