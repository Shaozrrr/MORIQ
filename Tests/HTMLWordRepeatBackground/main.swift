import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
let fm=FileManager.default
let root=fm.temporaryDirectory.appendingPathComponent("moriq-repeat-bg-\(UUID().uuidString)")
try fm.createDirectory(at:root,withIntermediateDirectories:true)
defer{try? fm.removeItem(at:root)}
let context=CGContext(data:nil,width:20,height:20,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));context.fill(CGRect(x:0,y:0,width:10,height:20))
context.setFillColor(CGColor(red:0,green:0,blue:1,alpha:1));context.fill(CGRect(x:10,y:0,width:10,height:20))
let tile=root.appendingPathComponent("tile.png"),dst=CGImageDestinationCreateWithURL(tile as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(dst,context.makeImage()!,nil);precondition(CGImageDestinationFinalize(dst))
let source=root.appendingPathComponent("sample.html")
let paragraphs=(0..<150).map{"<p>EDITABLE PARAGRAPH \($0)</p>"}.joined()
let html="<html><body style=\"margin:0;padding:0;background-image:url(tile.png);background-repeat:repeat;background-position:0px 0px;background-size:20px 20px\">\(paragraphs)</body></html>"
try html.write(to:source,atomically:true,encoding:.utf8)
let result=try DocumentConverter().convert(input:source,outputDirectory:root,format:UTType(filenameExtension:"docx")!)
let unzipProcess=Process();unzipProcess.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");unzipProcess.arguments=["-p",result.path,"word/document.xml"]
let pipe=Pipe();unzipProcess.standardOutput=pipe;try unzipProcess.run();let body=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);unzipProcess.waitUntilExit()
precondition(unzipProcess.terminationStatus==0 && body.contains("EDITABLE PARAGRAPH") && body.contains("headerReference"))
precondition(try! String(contentsOf:source,encoding:.utf8)==html)
if let path=ProcessInfo.processInfo.environment["MORIQ_REPEAT_OUTPUT"] {let to=URL(fileURLWithPath:path);try? fm.removeItem(at:to);try fm.copyItem(at:result,to:to)}
let defaultSource=root.appendingPathComponent("default-repeat.html")
let defaultHTML=html.replacingOccurrences(of:"background-repeat:repeat;",with:"")
try defaultHTML.write(to:defaultSource,atomically:true,encoding:.utf8)
let defaultResult=try DocumentConverter().convert(input:defaultSource,outputDirectory:root,format:UTType(filenameExtension:"docx")!)
let defaultUnzip=Process();defaultUnzip.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");defaultUnzip.arguments=["-p",defaultResult.path,"word/document.xml"]
let defaultPipe=Pipe();defaultUnzip.standardOutput=defaultPipe;try defaultUnzip.run();let defaultBody=String(decoding:defaultPipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);defaultUnzip.waitUntilExit()
precondition(defaultUnzip.terminationStatus==0 && defaultBody.contains("EDITABLE PARAGRAPH") && defaultBody.contains("headerReference"))
precondition(try! String(contentsOf:defaultSource,encoding:.utf8)==defaultHTML)
let coverSource=root.appendingPathComponent("cover.html")
let coverHTML="<html><body style=\"margin:0;padding:0;height:100vh;background-image:url(tile.png);background-repeat:no-repeat;background-position:center;background-size:cover\"><p>EDITABLE PARAGRAPH</p></body></html>"
try coverHTML.write(to:coverSource,atomically:true,encoding:.utf8)
let coverResult=try DocumentConverter().convert(input:coverSource,outputDirectory:root,format:UTType(filenameExtension:"docx")!)
let coverUnzip=Process();coverUnzip.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");coverUnzip.arguments=["-p",coverResult.path,"word/document.xml"]
let coverPipe=Pipe();coverUnzip.standardOutput=coverPipe;try coverUnzip.run();let coverBody=String(decoding:coverPipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);coverUnzip.waitUntilExit()
precondition(coverUnzip.terminationStatus==0 && coverBody.contains("EDITABLE PARAGRAPH") && coverBody.contains("headerReference"))
let imageUnzip=Process();imageUnzip.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");imageUnzip.arguments=["-p",coverResult.path,"word/media/moriq-page-background.png"]
let imagePipe=Pipe();imageUnzip.standardOutput=imagePipe;try imageUnzip.run();let imageData=imagePipe.fileHandleForReading.readDataToEndOfFile();imageUnzip.waitUntilExit()
guard let imageSource=CGImageSourceCreateWithData(imageData as CFData,nil), let image=CGImageSourceCreateImageAtIndex(imageSource,0,nil) else { fatalError("cover image missing") }
precondition(image.width > 500 && image.height > image.width)
let sample=CGContext(data:nil,width:2,height:1,bitsPerComponent:8,bytesPerRow:8,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
sample.interpolationQuality = .none; sample.draw(image,in:CGRect(x:0,y:0,width:2,height:1))
let pixels=sample.data!.assumingMemoryBound(to:UInt8.self)
precondition(pixels[0] > 180 && pixels[2] < 70 && pixels[4] < 70 && pixels[6] > 180, "cover should retain centered red/blue halves")
precondition(try! String(contentsOf:coverSource,encoding:.utf8)==coverHTML)
if let path=ProcessInfo.processInfo.environment["MORIQ_COVER_OUTPUT"] {let to=URL(fileURLWithPath:path);try? fm.removeItem(at:to);try fm.copyItem(at:coverResult,to:to)}
let complexSource=root.appendingPathComponent("complex-cover.html")
let complexHTML=html.replacingOccurrences(of:"background-repeat:repeat;background-position:0px 0px;background-size:20px 20px",with:"background-repeat:no-repeat;background-position:center;background-size:cover")
try complexHTML.write(to:complexSource,atomically:true,encoding:.utf8)
let complexResult=try DocumentConverter().convert(input:complexSource,outputDirectory:root,format:UTType(filenameExtension:"docx")!)
let complexUnzip=Process();complexUnzip.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");complexUnzip.arguments=["-p",complexResult.path,"word/document.xml"]
let complexPipe=Pipe();complexUnzip.standardOutput=complexPipe;try complexUnzip.run();let complexBody=String(decoding:complexPipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);complexUnzip.waitUntilExit()
precondition(complexUnzip.terminationStatus==0 && complexBody.contains("EDITABLE PARAGRAPH") && !complexBody.contains("rIdMoriqRepeatHeader"), "multi-page cover must not be silently approximated as a repeated page background")
let elementSource=root.appendingPathComponent("element.html")
let elementHTML="<html><body style=\"margin:0;padding:0\"><p style=\"margin:0;padding:0;width:200px;height:50px;background-image:url(tile.png);background-size:100% 100%;background-repeat:no-repeat\">HELLO</p></body></html>"
try elementHTML.write(to:elementSource,atomically:true,encoding:.utf8)
let elementResult=try DocumentConverter().convert(input:elementSource,outputDirectory:root,format:UTType(filenameExtension:"docx")!)
let elementUnzip=Process();elementUnzip.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");elementUnzip.arguments=["-p",elementResult.path,"word/document.xml"]
let elementPipe=Pipe();elementUnzip.standardOutput=elementPipe;try elementUnzip.run();let elementBody=String(decoding:elementPipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);elementUnzip.waitUntilExit()
precondition(elementUnzip.terminationStatus==0 && elementBody.contains("HELLO") && elementBody.contains("relativeFrom=\"paragraph\"") && elementBody.contains("relativeFrom=\"column\""), "element image must remain behind native paragraph text")
precondition(try! String(contentsOf:elementSource,encoding:.utf8)==elementHTML)
if let path=ProcessInfo.processInfo.environment["MORIQ_ELEMENT_OUTPUT"] {let to=URL(fileURLWithPath:path);try? fm.removeItem(at:to);try fm.copyItem(at:elementResult,to:to)}
let chineseSource=root.appendingPathComponent("element-chinese.html")
let chineseHTML=elementHTML.replacingOccurrences(of:"<html><body",with:"<html><head><meta charset=\"utf-8\"></head><body").replacingOccurrences(of:"HELLO",with:"你好世界")
try chineseHTML.write(to:chineseSource,atomically:true,encoding:.utf8)
let chineseResult=try DocumentConverter().convert(input:chineseSource,outputDirectory:root,format:UTType(filenameExtension:"docx")!)
let chineseUnzip=Process();chineseUnzip.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");chineseUnzip.arguments=["-p",chineseResult.path,"word/document.xml"]
let chinesePipe=Pipe();chineseUnzip.standardOutput=chinesePipe;try chineseUnzip.run();let chineseBody=String(decoding:chinesePipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);chineseUnzip.waitUntilExit()
precondition(chineseUnzip.terminationStatus==0 && chineseBody.contains("你好世界") && chineseBody.contains("relativeFrom=\"paragraph\""), "Chinese element image and text should remain together")
if let path=ProcessInfo.processInfo.environment["MORIQ_CHINESE_ELEMENT_OUTPUT"] {let to=URL(fileURLWithPath:path);try? fm.removeItem(at:to);try fm.copyItem(at:chineseResult,to:to)}
let longSource=root.appendingPathComponent("element-long.html")
let longHTML=chineseHTML.replacingOccurrences(of:"你好世界",with:"这是一段很长的中文标题")
try longHTML.write(to:longSource,atomically:true,encoding:.utf8)
let longResult=try DocumentConverter().convert(input:longSource,outputDirectory:root,format:UTType(filenameExtension:"docx")!)
let longUnzip=Process();longUnzip.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");longUnzip.arguments=["-p",longResult.path,"word/document.xml"]
let longPipe=Pipe();longUnzip.standardOutput=longPipe;try longUnzip.run();let longBody=String(decoding:longPipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);longUnzip.waitUntilExit()
precondition(longUnzip.terminationStatus==0 && longBody.contains("这是一段很长的中文标题") && !longBody.contains("rIdMoriqPageBackground"), "unsupported longer text must not receive an unchecked element overlay")
precondition(DocumentConverter.pdfResultNotice(input:longSource,targetExtension:"docx") != nil, "fallback must warn about background fidelity")
let tableSource=root.appendingPathComponent("table-element.html")
let tableHTML=chineseHTML.replacingOccurrences(of:"<p style=",with:"<table><tr><td style=").replacingOccurrences(of:"</p>",with:"</td></tr></table>")
try tableHTML.write(to:tableSource,atomically:true,encoding:.utf8)
let tableResult=try DocumentConverter().convert(input:tableSource,outputDirectory:root,format:UTType(filenameExtension:"docx")!)
let tableUnzip=Process();tableUnzip.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");tableUnzip.arguments=["-p",tableResult.path,"word/document.xml"]
let tablePipe=Pipe();tableUnzip.standardOutput=tablePipe;try tableUnzip.run();let tableBody=String(decoding:tablePipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);tableUnzip.waitUntilExit()
precondition(tableUnzip.terminationStatus==0 && tableBody.contains("你好世界") && tableBody.contains("relativeFrom=\"paragraph\"") && tableBody.contains("<w:tbl") && tableBody.contains("w:w=\"3000\"") && tableBody.contains("w:val=\"750\""), "single-cell image and CSS dimensions must stay behind native table-cell text")
if let path=ProcessInfo.processInfo.environment["MORIQ_TABLE_ELEMENT_OUTPUT"] {let to=URL(fileURLWithPath:path);try? fm.removeItem(at:to);try fm.copyItem(at:tableResult,to:to)}
let multiSource=root.appendingPathComponent("multi-cell.html")
let multiHTML=tableHTML.replacingOccurrences(of:"</td></tr>",with:"</td><td>第二格</td></tr>")
try multiHTML.write(to:multiSource,atomically:true,encoding:.utf8)
let multiResult=try DocumentConverter().convert(input:multiSource,outputDirectory:root,format:UTType(filenameExtension:"docx")!)
let multiUnzip=Process();multiUnzip.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");multiUnzip.arguments=["-p",multiResult.path,"word/document.xml"]
let multiPipe=Pipe();multiUnzip.standardOutput=multiPipe;try multiUnzip.run();let multiBody=String(decoding:multiPipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);multiUnzip.waitUntilExit()
precondition(multiUnzip.terminationStatus==0 && multiBody.contains("第二格") && !multiBody.contains("rIdMoriqPageBackground"), "unsupported multi-cell table must not receive a one-cell overlay")
precondition(DocumentConverter.pdfResultNotice(input:multiSource,targetExtension:"docx") != nil)
let twoSource=root.appendingPathComponent("two-cell.html")
let cellStyle="margin:0;padding:0;width:200px;height:50px;background-image:url(tile.png);background-size:100% 100%;background-repeat:no-repeat"
let twoHTML="<html><head><meta charset=\"utf-8\"></head><body style=\"margin:0;padding:0\"><table style=\"border-collapse:collapse\"><tr><td style=\"\(cellStyle)\">你好世界</td><td style=\"\(cellStyle)\">第二格</td></tr></table></body></html>"
try twoHTML.write(to:twoSource,atomically:true,encoding:.utf8)
let twoResult=try DocumentConverter().convert(input:twoSource,outputDirectory:root,format:UTType(filenameExtension:"docx")!)
let twoUnzip=Process();twoUnzip.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");twoUnzip.arguments=["-p",twoResult.path,"word/document.xml"]
let twoPipe=Pipe();twoUnzip.standardOutput=twoPipe;try twoUnzip.run();let twoBody=String(decoding:twoPipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);twoUnzip.waitUntilExit()
precondition(twoUnzip.terminationStatus==0 && twoBody.contains("你好世界") && twoBody.contains("第二格") && twoBody.contains("w:w=\"6000\"") && twoBody.contains("layoutInCell=\"0\""), "two-cell images and native text must remain together")
precondition(try! String(contentsOf:twoSource,encoding:.utf8)==twoHTML)
if let path=ProcessInfo.processInfo.environment["MORIQ_TWO_CELL_OUTPUT"] {let to=URL(fileURLWithPath:path);try? fm.removeItem(at:to);try fm.copyItem(at:twoResult,to:to)}
let duplicateSource=root.appendingPathComponent("duplicate-cell.html")
try twoHTML.replacingOccurrences(of:"第二格",with:"你好世界").write(to:duplicateSource,atomically:true,encoding:.utf8)
let duplicateResult=try DocumentConverter().convert(input:duplicateSource,outputDirectory:root,format:UTType(filenameExtension:"docx")!)
let duplicateUnzip=Process();duplicateUnzip.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");duplicateUnzip.arguments=["-p",duplicateResult.path,"word/document.xml"]
let duplicatePipe=Pipe();duplicateUnzip.standardOutput=duplicatePipe;try duplicateUnzip.run();let duplicateBody=String(decoding:duplicatePipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);duplicateUnzip.waitUntilExit()
precondition(duplicateUnzip.terminationStatus==0 && !duplicateBody.contains("rIdMoriqPageBackground"), "ambiguous duplicate cells must use the warned fallback")
let threeSource=root.appendingPathComponent("three-cell.html")
let threeHTML=twoHTML.replacingOccurrences(of:"</td></tr></table>",with:"</td><td style=\"\(cellStyle)\">第三格</td></tr></table>")
try threeHTML.write(to:threeSource,atomically:true,encoding:.utf8)
let threeResult=try DocumentConverter().convert(input:threeSource,outputDirectory:root,format:UTType(filenameExtension:"docx")!)
let threeUnzip=Process();threeUnzip.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");threeUnzip.arguments=["-p",threeResult.path,"word/document.xml"]
let threePipe=Pipe();threeUnzip.standardOutput=threePipe;try threeUnzip.run();let threeBody=String(decoding:threePipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);threeUnzip.waitUntilExit()
precondition(threeUnzip.terminationStatus==0 && threeBody.contains("第三格") && !threeBody.contains("rIdMoriqPageBackground"), "unverified three-cell layout must use the warned fallback")
precondition(DocumentConverter.pdfResultNotice(input:threeSource,targetExtension:"docx") != nil)
let greenContext=CGContext(data:nil,width:20,height:20,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
greenContext.setFillColor(CGColor(red:0,green:0.8,blue:0,alpha:1)); greenContext.fill(CGRect(x:0,y:0,width:20,height:20))
let greenURL=root.appendingPathComponent("green.png"),greenDest=CGImageDestinationCreateWithURL(greenURL as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(greenDest,greenContext.makeImage()!,nil);precondition(CGImageDestinationFinalize(greenDest))
let gridSource=root.appendingPathComponent("grid.html"), greenStyle=cellStyle.replacingOccurrences(of:"tile.png",with:"green.png")
let gridHTML=twoHTML.replacingOccurrences(of:"</tr></table>",with:"</tr><tr><td style=\"\(greenStyle)\">第三格</td><td style=\"\(greenStyle)\">第四格</td></tr></table>")
try gridHTML.write(to:gridSource,atomically:true,encoding:.utf8)
let gridResult=try DocumentConverter().convert(input:gridSource,outputDirectory:root,format:UTType(filenameExtension:"docx")!)
let gridUnzip=Process();gridUnzip.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");gridUnzip.arguments=["-p",gridResult.path,"word/document.xml"]
let gridPipe=Pipe();gridUnzip.standardOutput=gridPipe;try gridUnzip.run();let gridBody=String(decoding:gridPipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);gridUnzip.waitUntilExit()
precondition(gridUnzip.terminationStatus==0 && gridBody.contains("你好世界") && gridBody.contains("第四格") && gridBody.contains("layoutInCell=\"0\"") && gridBody.components(separatedBy:"w:trHeight").count-1 >= 2, "grid background must retain native text and each row height")
precondition(try! String(contentsOf:gridSource,encoding:.utf8)==gridHTML)
if let path=ProcessInfo.processInfo.environment["MORIQ_GRID_OUTPUT"] {let to=URL(fileURLWithPath:path);try? fm.removeItem(at:to);try fm.copyItem(at:gridResult,to:to)}
let threeRowsSource=root.appendingPathComponent("three-rows.html")
let threeRowsHTML=gridHTML.replacingOccurrences(of:"</tr></table>",with:"</tr><tr><td style=\"\(greenStyle)\">第五格</td><td style=\"\(greenStyle)\">第六格</td></tr></table>")
try threeRowsHTML.write(to:threeRowsSource,atomically:true,encoding:.utf8)
let threeRowsResult=try DocumentConverter().convert(input:threeRowsSource,outputDirectory:root,format:UTType(filenameExtension:"docx")!)
let threeRowsUnzip=Process();threeRowsUnzip.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");threeRowsUnzip.arguments=["-p",threeRowsResult.path,"word/document.xml"]
let threeRowsPipe=Pipe();threeRowsUnzip.standardOutput=threeRowsPipe;try threeRowsUnzip.run();let threeRowsBody=String(decoding:threeRowsPipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);threeRowsUnzip.waitUntilExit()
precondition(threeRowsUnzip.terminationStatus==0 && threeRowsBody.contains("第六格") && !threeRowsBody.contains("rIdMoriqPageBackground"), "unverified three-row layout must use the warned fallback")
precondition(DocumentConverter.pdfResultNotice(input:threeRowsSource,targetExtension:"docx") != nil)
print("PASS explicit/default repeat and centered cover, native text and source retained")
