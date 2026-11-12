import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import PDFKit
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("moriq-element-cover-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories:true)
defer { try? fm.removeItem(at:root) }
let ctx = CGContext(data:nil,width:300,height:100,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
for (x,c) in [(0,NSColor.red),(100,NSColor.green),(200,NSColor.blue)] { ctx.setFillColor(c.cgColor); ctx.fill(CGRect(x:x,y:0,width:100,height:100)) }
let dest = CGImageDestinationCreateWithURL(root.appendingPathComponent("bands.png") as CFURL, UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(dest,ctx.makeImage()!,nil); precondition(CGImageDestinationFinalize(dest))
let src = root.appendingPathComponent("cover.html")
let html = "<html><body style='margin:0;padding:0'><p style='margin:0;padding:0;width:200px;height:100px;background-image:url(bands.png);background-size:cover;background-position:center;background-repeat:no-repeat'>你好世界</p></body></html>"
try html.write(to:src,atomically:true,encoding:.utf8)
let result = try DocumentConverter().convert(input:src,outputDirectory:root,format:UTType(filenameExtension:"docx")!)
func part(_ name:String)->Data { let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");p.arguments=["-p",result.path,name];let pipe=Pipe();p.standardOutput=pipe;try! p.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();precondition(p.terminationStatus==0);return data }
let body=String(decoding:part("word/document.xml"),as:UTF8.self)
precondition(body.contains("你好世界") && body.contains("behindDoc=\"1\""),"editable text or background lost")
let img=CGImageSourceCreateWithData(part("word/media/moriq-page-background.png") as CFData,nil)!
let image=CGImageSourceCreateImageAtIndex(img,0,nil)!
precondition(image.width==200 && image.height==100)
let pixels=calloc(200*100,4)!
let check=CGContext(data:pixels,width:200,height:100,bitsPerComponent:8,bytesPerRow:800,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
check.draw(image,in:CGRect(x:0,y:0,width:200,height:100))
let p=pixels.assumingMemoryBound(to:UInt8.self)
func rgb(_ x:Int)->(UInt8,UInt8,UInt8) {let i=(50*200+x)*4;return(p[i],p[i+1],p[i+2])}
let left=rgb(10), mid=rgb(100), right=rgb(190)
precondition(left.0>200 && mid.1>200 && right.2>200,"cover crop incorrect")
free(pixels)
precondition((try! String(contentsOf:src,encoding:.utf8))==html)
let pdfURL = try DocumentConverter().convert(input:result,outputDirectory:root,format:.pdf)
let pdf = PDFDocument(url:pdfURL)!
precondition(pdf.string?.contains("你好世界") == true, "CJK text missing from PDF")
let thumbnail = pdf.page(at:0)!.thumbnail(of:CGSize(width:1190,height:1684),for:.mediaBox)
let bitmap = NSBitmapImageRep(data:thumbnail.tiffRepresentation!)!
var ink = 0
for y in 55..<105 { for x in 108..<350 {
    if let c = bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB), c.redComponent < 0.2 && c.greenComponent < 0.2 && c.blueComponent < 0.2 { ink += 1 }
} }
precondition(ink > 15,"CJK text not visibly rendered over the background")
if let path=ProcessInfo.processInfo.environment["MORIQ_COVER_OUTPUT"] { try fm.copyItem(at:result,to:URL(fileURLWithPath:path)) }
print("PASS Word center cover and CJK text visibly rendered in PDF via bundled office")
