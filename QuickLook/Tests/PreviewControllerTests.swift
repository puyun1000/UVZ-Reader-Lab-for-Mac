import AppKit
import PDFKit
import QuickLookUI

@main struct PreviewControllerTest {
 static func main() {
  let app = NSApplication.shared, delegate = PreviewTestDelegate(); app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
 }
}
final class PreviewTestDelegate: NSObject,NSApplicationDelegate {
 let window = NSWindow(contentRect:NSRect(x:0,y:0,width:820,height:880),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
 let controller = PreviewProvider()
 var beforeResize: CGFloat = 0, manualScale: CGFloat = 0
 var stage = 0,reply = false,checks: [String] = [],deadline = Date().addingTimeInterval(30)
 func applicationDidFinishLaunching(_ note: Notification) {
  window.contentViewController = controller; window.makeKeyAndOrderFront(nil)
  controller.preparePreviewOfFile(at:URL(fileURLWithPath:CommandLine.arguments[1])) { error in if let error { self.fail(error.localizedDescription) }; self.reply = true }
  tick()
 }
 func fail(_ value: String) -> Never { fputs("PREVIEW_TEST_FAILED \(value) stage=\(stage)\n",stderr); exit(1) }
 func assert(_ yes: Bool,_ title: String) { if !yes { fail(title) }; checks.append(title) }
 func color(_ rgb: [CGFloat]) -> Bool {
  guard let ns=controller.image.image,let cg=ns.cgImage(forProposedRect:nil,context:nil,hints:nil) else{return false}
  let rep=NSBitmapImageRep(cgImage:cg);guard let c=rep.colorAt(x:cg.width/2,y:cg.height/2)?.usingColorSpace(.sRGB) else{return false}
  let components = [c.redComponent,c.greenComponent,c.blueComponent], axis = rgb.firstIndex(of:1)!
  return components[axis]>0.8 && components.enumerated().allSatisfy { $0.offset == axis || $0.element<0.4 }
 }
 func tick() { DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [self] in
  if Date()>deadline {fail("timeout")}
  switch stage {
  case 0:
   guard reply,controller.image.image != nil else {tick();return}
   assert(controller.book?.pages.count == 3 && color([1,0,0]),"首次显示第1页及总页数")
   assert(!controller.previous.isEnabled && controller.next.isEnabled,"首页导航边界正确")
   controller.nextPage();stage=1
  case 1:
   guard controller.image.image != nil else {tick();return}
   assert(controller.currentPage == 1 && color([0,0,1]),"下一页实际解码并显示第2页，而非重复封面")
   controller.pageField.stringValue="3";controller.goToPage();stage=2
  case 2:
   guard controller.image.image != nil else {tick();return}
   assert(controller.currentPage == 2 && color([0,1,0]) && !controller.next.isEnabled,"输入页码进入末页并禁用继续前进")
   let scale=controller.scroll.magnification;controller.zoomIn();assert(controller.scroll.magnification>scale,"预览支持缩放")
   controller.fitPage();assert(controller.scroll.magnification<=min(controller.scroll.frame.width/600,controller.scroll.frame.height/800)+0.01 && controller.scroll.magnification>0.05,"适合整页可恢复缩放")
   beforeResize = controller.scroll.magnification
   window.setContentSize(NSSize(width:window.contentLayoutRect.width+200,height:window.contentLayoutRect.height+200));stage=3
  case 3:
   controller.view.layoutSubtreeIfNeeded()
   assert(controller.scroll.magnification>beforeResize,"放大窗口后整页自动适配")
   controller.zoomIn();manualScale = controller.scroll.magnification
   window.setContentSize(NSSize(width:860,height:780));stage=4
  case 4:
   controller.view.layoutSubtreeIfNeeded()
   assert(abs(controller.scroll.magnification-manualScale)<0.001,"手动缩放后调整窗口保留缩放")
   controller.fitPage();assert(controller.scroll.magnification<manualScale,"选择适合整页恢复随窗口适配")
   controller.pageField.stringValue="999";controller.goToPage();assert(controller.currentPage == 2 && controller.pageField.integerValue == 3,"越界页码不会改变当前页")
   controller.showPage(0);controller.showPage(2);stage=5
  default:
   guard controller.image.image != nil else {tick();return}
   assert(controller.currentPage == 2 && color([0,1,0]),"连续跳页保留最后请求，旧图不覆盖新页")
   let v=window.contentView!;v.layoutSubtreeIfNeeded();let rep=v.bitmapImageRepForCachingDisplay(in:v.bounds)!;v.cacheDisplay(in:v.bounds,to:rep)
   try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
   let data=try! JSONSerialization.data(withJSONObject:["passed":checks.count,"checks":checks],options:[.prettyPrinted,.sortedKeys]);FileHandle.standardOutput.write(data);exit(0)
  }
  tick()
 } }
}
