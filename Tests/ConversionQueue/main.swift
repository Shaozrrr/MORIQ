import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
@main struct Test {
    static func main() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moriq-queue-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let context = CGContext(data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
        let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(destination))
        let jpeg = try! ImageConverter().convert(input: source, outputDirectory: directory, format: .jpeg)
        let animated = directory.appendingPathComponent("animated.gif")
        let gif = CGImageDestinationCreateWithURL(animated as CFURL, UTType.gif.identifier as CFString, 2, nil)!
        for color in [NSColor.red, NSColor.blue] {
            context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
            CGImageDestinationAddImage(gif, context.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.4]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(gif) && ExternalMediaConverter.isAnimatedImage(animated))
        let multipage = directory.appendingPathComponent("multipage.tiff")
        let tiff = CGImageDestinationCreateWithURL(multipage as CFURL, UTType.tiff.identifier as CFString, 2, nil)!
        for _ in 0..<2 { CGImageDestinationAddImage(tiff, context.makeImage()!, nil) }
        precondition(CGImageDestinationFinalize(tiff))
        let pdf = directory.appendingPathComponent("pages.pdf")
        let consumer = CGDataConsumer(url: pdf as CFURL)!
        var pdfBox = CGRect(x: 0, y: 0, width: 30, height: 20)
        let pdfContext = CGContext(consumer: consumer, mediaBox: &pdfBox, nil)!
        for color in [NSColor.red, NSColor.blue] {
            pdfContext.beginPDFPage(nil); pdfContext.setFillColor(color.cgColor); pdfContext.fill(pdfBox); pdfContext.endPDFPage()
        }
        pdfContext.closePDF()
        let bad = directory.appendingPathComponent("bad.png"); try! Data("bad".utf8).write(to: bad)
        let coordinator = await MainActor.run { ConversionCoordinator(presentsNotices: false) }
        let counter = await MainActor.run { Counter() }
        await MainActor.run {
            coordinator.onResults = { results in counter.reports.append(results) }
            coordinator.enqueueConversion([source], to: .jpeg)
            coordinator.enqueueConversion([source], to: .tiff)
            coordinator.enqueueConversion([bad], to: .png)
            coordinator.enqueueConversion([source, jpeg], to: .png)
            coordinator.enqueueConversion([source, jpeg], to: .zip)
            coordinator.enqueueConversion([animated], to: UTType(filenameExtension: "mp4")!)
            coordinator.enqueueConversion([multipage], to: .png)
            coordinator.enqueueConversion([multipage], to: .jpeg)
            coordinator.enqueueConversion([multipage], to: .gif)
            coordinator.enqueueConversion([multipage], to: UTType("public.avif")!)
            coordinator.enqueueConversion([multipage], to: UTType("org.webmproject.webp")!)
            coordinator.enqueueConversion([pdf], to: .heic)
            coordinator.enqueueConversion([pdf], to: .gif)
            coordinator.enqueueConversion([pdf], to: UTType("org.webmproject.webp")!)
        }
        for _ in 0..<400 {
            if await MainActor.run(body: { counter.reports.count == 14 }) { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        await MainActor.run {
            precondition(counter.reports.count == 14)
            precondition(counter.reports[0][0].output != nil && counter.reports[1][0].output != nil)
            precondition(counter.reports[2][0].output == nil && !counter.reports[2][0].message.isEmpty)
            precondition(counter.reports[3].count == 2)
            precondition(counter.reports[3][0].output == source && counter.reports[3][0].message.contains("已是目标格式"))
            precondition(counter.reports[3][1].output != nil && counter.reports[3][1].output != jpeg)
            precondition(counter.reports[4].count == 1 && counter.reports[4][0].message.contains("2 项打包"))
            let zip = counter.reports[4][0].output!
            precondition(zip.pathExtension == "zip" && FileManager.default.fileExists(atPath: zip.path))
            precondition(counter.reports[5][0].output?.pathExtension == "mp4")
            precondition(counter.reports[6][0].message.contains("逐页导出"))
            precondition(counter.reports[7][0].message.contains("有损压缩"))
            precondition(counter.reports[8][0].message.contains("量化"))
            precondition(counter.reports[9][0].message.contains("元数据"))
            precondition(counter.reports[10][0].message.contains("元数据"))
            precondition(counter.reports[12][0].message.contains("量化"))
            for index in [6, 7, 8, 9, 10] {
                let folder = counter.reports[index][0].output!
                let contents = try! FileManager.default.contentsOfDirectory(atPath: folder.path)
                precondition(contents.count == 2)
            }
            for index in [11, 12, 13] {
                let folder = counter.reports[index][0].output!
                precondition((try! FileManager.default.contentsOfDirectory(atPath: folder.path)).count == 2)
            }
            precondition(FileManager.default.fileExists(atPath: animated.path))
            precondition(FileManager.default.fileExists(atPath: source.path))
        }
        print("PASS: mixed conversion and rapid jobs complete in order and report failures without removing source")
    }
    @MainActor final class Counter { var reports: [[ConversionRecord]] = [] }
}
