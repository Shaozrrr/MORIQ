import AppKit
import CoreText
import Foundation
import PDFKit
import UniformTypeIdentifiers
let fm = FileManager.default
precondition(DocumentConverter.packagedPDFEngine != nil && DocumentConverter.officeEngine != nil)
let root = fm.temporaryDirectory.appendingPathComponent("moriq-pdf-formats-\(UUID().uuidString)", isDirectory:true)
try fm.createDirectory(at:root,withIntermediateDirectories:true)
defer { try? fm.removeItem(at:root) }
let source=root.appendingPathComponent("mixed.pdf"); var box=CGRect(x:0,y:0,width:400,height:400)
let pdf=CGContext(consumer:CGDataConsumer(url:source as CFURL)!,mediaBox:&box,nil)!
pdf.beginPDFPage(nil);pdf.setFillColor(NSColor.white.cgColor);pdf.fill(box)
let font=CTFontCreateWithName("Helvetica-Bold" as CFString,24,nil)
let line=CTLineCreateWithAttributedString(NSAttributedString(string:"MORIQ IMAGE 7193",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):NSColor.black.cgColor]))
pdf.textPosition=CGPoint(x:30,y:330);CTLineDraw(line,pdf)
let ctx=CGContext(data:nil,width:100,height:80,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(NSColor.systemBlue.cgColor);ctx.fill(CGRect(x:0,y:0,width:100,height:80));pdf.draw(ctx.makeImage()!,in:CGRect(x:40,y:100,width:200,height:160));pdf.endPDFPage();pdf.closePDF()
for ext in ["docx","rtf","html","odt"] {
 let format=UTType(filenameExtension:ext)!,dir=root.appendingPathComponent(ext,isDirectory:true);try fm.createDirectory(at:dir,withIntermediateDirectories:false)
 let out=try DocumentConverter().convert(input:source,outputDirectory:dir,format:format)
 if ext=="rtf" {let d=try Data(contentsOf:out);let text=String(decoding:d,as:UTF8.self);precondition(text.contains("MORIQ") && text.contains("\\pict"),"RTF lost text or image")}
 else if ext=="html" {let text=try String(contentsOf:out,encoding:.utf8);precondition(text.contains("MORIQ") && text.contains("data:image/"),"HTML lost text or embedded image")}
 else {let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");p.arguments=["-Z1",out.path];let pipe=Pipe();p.standardOutput=pipe;try p.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();let listing=String(decoding:data,as:UTF8.self);precondition(listing.contains(ext=="docx" ? "word/media/" : "Pictures/"),"document lost image")
  let reader=Process();reader.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");reader.arguments=["-p",out.path,ext=="docx" ? "word/document.xml" : "content.xml"];let content=Pipe();reader.standardOutput=content;try reader.run();let textData=content.fileHandleForReading.readDataToEndOfFile();reader.waitUntilExit();precondition(String(decoding:textData,as:UTF8.self).contains("MORIQ"),"document lost text")}
 print("PASS PDF->\(ext) image and text path");fflush(stdout)
}
