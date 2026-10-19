import AppKit
import QuickLookThumbnailing
let args=CommandLine.arguments
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
let url=URL(fileURLWithPath:args[1]).standardizedFileURL
let request=QLThumbnailGenerator.Request(fileAt:url,size:CGSize(width:800,height:800),scale:1,representationTypes:.thumbnail)
var finished=false
var succeeded=false
QLThumbnailGenerator.shared.generateBestRepresentation(for:request) { rep,error in
 if let rep, rep.type == .thumbnail {
  succeeded=true
  let png=NSBitmapImageRep(cgImage:rep.cgImage).representation(using:.png,properties:[:])!
  try! png.write(to:URL(fileURLWithPath:args[2]));print("THUMB_OK \(rep.type.rawValue) \(rep.cgImage.width)x\(rep.cgImage.height)")
 } else {fputs("THUMB_ERROR \(String(describing:error))\n",stderr)}
 finished=true
}
let until=Date().addingTimeInterval(20)
while !finished && Date()<until { RunLoop.main.run(until:Date().addingTimeInterval(0.1)) }
if !finished {fputs("THUMB_TIMEOUT\n",stderr);exit(2)}
if !succeeded {exit(1)}
