import AppKit
@main struct Main {static func main(){let app=NSApplication.shared,d=Probe();app.delegate=d;app.setActivationPolicy(.accessory);app.run()}}
final class Probe:NSObject,NSApplicationDelegate {
 let window=ChineseWindow(contentRect:NSRect(x:0,y:0,width:380,height:100),styleMask:[.titled],backing:.buffered,defer:false)
 var field:CenteredTextField!,index=0,results:[[String:Any]]=[]
 let cases:[(CGFloat,CGFloat)]=[(26,13),(32,13),(40,13),(26,15),(32,15),(40,15)]
 func applicationDidFinishLaunching(_ n:Notification){window.makeKeyAndOrderFront(nil);next()}
 func bounds(_ suffix:String)->[Int] {
  let host=window.contentView!;window.display();let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds)!;host.cacheDisplay(in:host.bounds,to:rep)
  let png=rep.representation(using:.png,properties:[:])!;try! png.write(to:URL(fileURLWithPath:CommandLine.arguments[1]+"-\(index)-"+suffix+".png"))
  let cg=rep.cgImage!,w=cg.width,h=cg.height
  let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(cg,in:CGRect(x:0,y:0,width:w,height:h))
  let bytes=context.data!.assumingMemoryBound(to:UInt8.self);var ys:[Int]=[]
  for y in 0..<h {for x in 0..<w {
   let at=(y*w+x)*4,r=Double(bytes[at]),g=Double(bytes[at+1]),b=Double(bytes[at+2])
   if r>160 && r>g*1.8 && r>b*1.8 {ys.append(y)}
  }}
  return [ys.min() ?? -1,ys.max() ?? -1]
 }
 func next(){
  if index==cases.count {let pass=results.allSatisfy {($0["delta"] as! Int)<=1 && ($0["editing"] as! [Int])[0]>=0};let data=try! JSONSerialization.data(withJSONObject:["passed":pass,"checks":results],options:.prettyPrinted);print(String(decoding:data,as:UTF8.self));exit(pass ? 0:1)}
  let (height,font)=cases[index];field=CenteredTextField(string:"居中ABC");field.frame=NSRect(x:20,y:20,width:300,height:height);field.font = .systemFont(ofSize:font);field.textColor = .red;window.contentView!.addSubview(field)
  field.selectText(nil);let editor=window.fieldEditor(true,for:field) as! NSTextView;editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0));editor.insertText("g",replacementRange:editor.selectedRange())
  DispatchQueue.main.asyncAfter(deadline:.now()+0.1){
   let editing=self.bounds("editing");self.window.makeFirstResponder(nil)
   DispatchQueue.main.asyncAfter(deadline:.now()+0.1){
    let idle=self.bounds("idle"),delta=max(abs(editing[0]-idle[0]),abs(editing[1]-idle[1]))
    self.results.append(["height":height,"font":font,"editing":editing,"idle":idle,"delta":delta]);self.field.removeFromSuperview();self.index += 1;self.next()
   }
  }
 }
}
