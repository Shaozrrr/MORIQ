import Foundation
import ImageIO
import UniformTypeIdentifiers
let root = URL(fileURLWithPath:"/tmp/moriq-wk-background-probe",isDirectory:true)
let original = root.appendingPathComponent("snapshot-element.png")
guard let source = CGImageSourceCreateWithURL(original as CFURL,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil), let crop = image.cropping(to:CGRect(x:120,y:100,width:240,height:160)) else { fatalError("run WebKit background probe first") }
let tile = root.appendingPathComponent("element-background.png")
guard let dest=CGImageDestinationCreateWithURL(tile as CFURL,UTType.png.identifier as CFString,1,nil) else { fatalError("image destination") }
CGImageDestinationAddImage(dest,crop,nil); precondition(CGImageDestinationFinalize(dest))
let html = "<html><body style=\"margin:0;padding:0;background-image:url(element-background.png);background-repeat:no-repeat;background-position:0px 0px;background-size:120px 80px\"><p>INTRODUCTION TEXT</p><p>CARD TEXT</p></body></html>"
let input = root.appendingPathComponent("paragraph-prototype.html")
try html.write(to:input,atomically:true,encoding:.utf8)
let output = try DocumentConverter().convert(input:input,outputDirectory:root,format:UTType(filenameExtension:"docx")!)
let target = root.appendingPathComponent("paragraph-before.docx")
try? FileManager.default.removeItem(at:target); try FileManager.default.copyItem(at:output,to:target)
print("PASS staged Word paragraph sample: \(target.path)")
