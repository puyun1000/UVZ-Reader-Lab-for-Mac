import AppKit
import QuickLookUI
final class Delegate: NSObject,NSApplicationDelegate {
 var preview:QLPreviewView!
 let window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
 func applicationDidFinishLaunching(_ note:Notification){
  preview=QLPreviewView(frame:window.contentView!.bounds,style:.normal)
  preview.autoresizingMask=[.width,.height];window.contentView!.addSubview(preview)
  preview.previewItem=NSURL(fileURLWithPath:CommandLine.arguments[1])
  window.makeKeyAndOrderFront(nil)
  DispatchQueue.main.asyncAfter(deadline:.now()+10){
   print("PREVIEW_HOST_OK");exit(0)
  }
 }
}
let app=NSApplication.shared;let delegate=Delegate();app.delegate=delegate;app.setActivationPolicy(.accessory);app.run()
