import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum PDFPageExportError: Error { case invalid, tooManyPages, render, filesystem(Int32) }
struct PDFPageExporter {
    static func supportedFormats() -> [UTType] {
        let candidates: [UTType] = [.png, .jpeg, .tiff, .heic, .gif] + ["com.microsoft.bmp", "public.avif", "public.jpeg-2000"].compactMap(UTType.init)
        let encoders = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        return candidates.filter { encoders.contains($0.identifier) }
    }
    func convert(input: URL, outputDirectory: URL, format: UTType) throws -> URL {
        try Task.checkCancellation()
        guard Self.supportedFormats().contains(format), let ext = format.preferredFilenameExtension,
              let document = PDFDocument(url: input), !document.isLocked, document.pageCount > 0 else { throw PDFPageExportError.invalid }
        guard document.pageCount <= 500 else { throw PDFPageExportError.tooManyPages }
        let scratch = outputDirectory.appendingPathComponent(".moriq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var files: [URL] = []
        for index in 0..<document.pageCount {
          try Task.checkCancellation()
          // PDFKit and AppKit create autoreleased image objects per page.
          // Release them before rendering the next page in a long document.
          let file: URL = try autoreleasepool {
            guard let page = document.page(at: index) else { throw PDFPageExportError.invalid }
            let bounds = page.bounds(for: .cropBox)
            guard bounds.width > 0, bounds.height > 0 else { throw PDFPageExportError.invalid }
            let scale = min(2, 6000 / max(bounds.width, bounds.height))
            let sideways = ((page.rotation % 180) + 180) % 180 == 90
            let width = max(1, Int(((sideways ? bounds.height : bounds.width) * scale).rounded()))
            let height = max(1, Int(((sideways ? bounds.width : bounds.height) * scale).rounded()))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PDFPageExportError.render }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let thumbnail = page.thumbnail(of: NSSize(width: width, height: height), for: .cropBox)
            var rect = NSRect(origin: .zero, size: thumbnail.size)
            guard let rendered = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw PDFPageExportError.render }
            context.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage() else { throw PDFPageExportError.render }
            let temp = scratch.appendingPathComponent(String(format: "%03d.%@", index + 1, ext))
            guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, format.identifier as CFString, 1, nil) else { throw PDFPageExportError.render }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw PDFPageExportError.render }
            return temp
          }
          try Task.checkCancellation()
          files.append(file)
        }
        let name = input.deletingPathExtension().lastPathComponent
        if files.count == 1 {
            for n in 1...10000 {
                try Task.checkCancellation()
                let suffix = n == 1 ? "" : " (\(n))"
                let target = outputDirectory.appendingPathComponent("\(name)\(suffix).\(ext)")
                let result = files[0].withUnsafeFileSystemRepresentation { src in target.withUnsafeFileSystemRepresentation { dst in link(src!, dst!) } }
                if result == 0 { return target }
                if errno != EEXIST { throw PDFPageExportError.filesystem(errno) }
            }
        } else {
            for n in 1...10000 {
                try Task.checkCancellation()
                let suffix = n == 1 ? "" : " (\(n))"
                let folder = outputDirectory.appendingPathComponent("\(name) 页面\(suffix)", isDirectory: true)
                // Publish the completed folder in one operation: consumers never
                // see a partly moved set of pages after cancellation or failure.
                let result = scratch.withUnsafeFileSystemRepresentation { src in
                    folder.withUnsafeFileSystemRepresentation { dst in renamex_np(src!, dst!, UInt32(RENAME_EXCL)) }
                }
                if result == 0 { return folder }
                if errno != EEXIST { throw PDFPageExportError.filesystem(errno) }
            }
        }
        throw PDFPageExportError.render
    }
}
