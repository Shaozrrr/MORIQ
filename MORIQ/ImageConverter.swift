import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin
import PDFKit

enum ImageConversionError: Error { case invalidInput, unsupportedOutput, cannotCreateOutput, encodingFailed, validationFailed, noAvailableName, filesystem(Int32) }
struct ImageConverter {
    #if DEBUG
    var debugBeforePublish: (@Sendable () -> Void)? = nil
    #endif
    private func beforePublish() throws {
        #if DEBUG
        debugBeforePublish?()
        #endif
        try Task.checkCancellation()
    }
    static let allowed: [UTType] = [.png, .jpeg, .tiff, .heic]
    static let additionalOutputs: [UTType] = [UTType.gif, UTType("com.microsoft.bmp")!, UTType("public.avif")!, UTType("public.jpeg-2000")!]
    static let allowedInputs: [UTType] = allowed + additionalOutputs + [UTType("org.webmproject.webp")!]
    private static func pdfPageSize(image: CGImage, properties: [CFString: Any]) -> CGSize {
        func dpi(_ key: CFString) -> CGFloat {
            guard let value = (properties[key] as? NSNumber)?.doubleValue, value.isFinite, (1...9600).contains(value) else { return 72 }
            return CGFloat(value)
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let x = dpi(rotated ? kCGImagePropertyDPIHeight : kCGImagePropertyDPIWidth)
        let y = dpi(rotated ? kCGImagePropertyDPIWidth : kCGImagePropertyDPIHeight)
        return CGSize(width: CGFloat(image.width) * 72 / x, height: CGFloat(image.height) * 72 / y)
    }
    static func isMultipageTIFF(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?, UTType(type)?.conforms(to: .tiff) == true else { return false }
        return CGImageSourceGetCount(source) > 1
    }
    private static func imageForOutput(source: CGImageSource, index: Int, original: CGImage, format: UTType) throws -> (CGImage, CFDictionary?) {
        guard format.identifier == "public.avif" else { return (original, CGImageSourceCopyPropertiesAtIndex(source, index, nil)) }
        var metadata = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let orientation = (metadata[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (2...8).contains(orientation) else { return (original, metadata as CFDictionary) }
        // AVIF output may discard orientation; apply it to pixels and update
        // metadata so a viewer cannot rotate the image a second time.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(original.width, original.height)]
        guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { throw ImageConversionError.invalidInput }
        if (5...8).contains(orientation) {
            let widthDPI = metadata[kCGImagePropertyDPIWidth], heightDPI = metadata[kCGImagePropertyDPIHeight]
            metadata[kCGImagePropertyDPIWidth] = heightDPI; metadata[kCGImagePropertyDPIHeight] = widthDPI
        }
        metadata[kCGImagePropertyOrientation] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1; metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = oriented.width
            exif[kCGImagePropertyExifPixelYDimension] = oriented.height
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        return (oriented, metadata as CFDictionary)
    }
    private func multipageTIFFToImages(source: CGImageSource, input: URL, outputDirectory: URL, format: UTType) throws -> URL {
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= 500, (Self.allowed + Self.additionalOutputs).contains(format), let ext = format.preferredFilenameExtension else { throw ImageConversionError.invalidInput }
        let scratch = outputDirectory.appendingPathComponent(".moriq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for index in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let original = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw ImageConversionError.invalidInput }
                let (image, properties) = try Self.imageForOutput(source: source, index: index, original: original, format: format)
                try Task.checkCancellation()
                let page = scratch.appendingPathComponent(String(format: "%03d.%@", index + 1, ext))
                guard let destination = CGImageDestinationCreateWithURL(page as CFURL, format.identifier as CFString, 1, nil) else { throw ImageConversionError.cannotCreateOutput }
                CGImageDestinationAddImage(destination, image, properties)
                guard CGImageDestinationFinalize(destination), let check = CGImageSourceCreateWithURL(page as CFURL, nil), CGImageSourceCreateImageAtIndex(check, 0, nil) != nil else { throw ImageConversionError.validationFailed }
            }
        }
        try beforePublish()
        let name = input.deletingPathExtension().lastPathComponent
        for number in 1...10000 {
            try Task.checkCancellation()
            let suffix = number == 1 ? "" : " (\(number))"
            let folder = outputDirectory.appendingPathComponent("\(name) 页面\(suffix)", isDirectory: true)
            let result = scratch.withUnsafeFileSystemRepresentation { src in folder.withUnsafeFileSystemRepresentation { dst in renamex_np(src!, dst!, UInt32(RENAME_EXCL)) } }
            if result == 0 { return folder }
            if errno != EEXIST { throw ImageConversionError.filesystem(errno) }
        }
        throw ImageConversionError.noAvailableName
    }
    private func multipageTIFFToPDF(source: CGImageSource, input: URL, outputDirectory: URL) throws -> URL {
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= 500 else { throw ImageConversionError.invalidInput }
        let temp = outputDirectory.appendingPathComponent(".moriq-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let consumer = CGDataConsumer(url: temp as CFURL), let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ImageConversionError.cannotCreateOutput }
        var closed = false
        defer { if !closed { pdf.closePDF() } }
        for index in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0 else { throw ImageConversionError.invalidInput }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { throw ImageConversionError.invalidInput }
                try Task.checkCancellation()
                var box = CGRect(origin: .zero, size: Self.pdfPageSize(image: image, properties: props))
                let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
                pdf.beginPDFPage([kCGPDFContextMediaBox: data] as CFDictionary)
                pdf.draw(image, in: box); pdf.endPDFPage()
            }
        }
        pdf.closePDF(); closed = true
        try Task.checkCancellation()
        guard let check = PDFDocument(url: temp), check.pageCount == count else { throw ImageConversionError.validationFailed }
        try beforePublish()
        let name = input.deletingPathExtension().lastPathComponent
        for number in 1...10000 {
            try Task.checkCancellation()
            let suffix = number == 1 ? "" : " (\(number))"
            let output = outputDirectory.appendingPathComponent("\(name)\(suffix).pdf")
            let result = temp.withUnsafeFileSystemRepresentation { src in output.withUnsafeFileSystemRepresentation { dst in link(src!, dst!) } }
            if result == 0 { return output }
            if errno != EEXIST { throw ImageConversionError.filesystem(errno) }
        }
        throw ImageConversionError.noAvailableName
    }
    static func resultNotice(input: URL, output: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), let before = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let result = CGImageSourceCreateWithURL(output as CFURL, nil), let after = CGImageSourceCreateImageAtIndex(result, 0, nil) else { return nil }
        func hasAlpha(_ image: CGImage) -> Bool {
            switch image.alphaInfo { case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: return true; default: return false }
        }
        var changes: [String] = []
        if hasAlpha(before) && !hasAlpha(after) { changes.append("透明通道未保留") }
        if after.bitsPerComponent < before.bitsPerComponent { changes.append("色彩精度降低") }
        switch output.pathExtension.lowercased() {
        case "jpg", "jpeg": changes.append("使用有损压缩")
        case "gif": changes.append("颜色已量化")
        default: break
        }
        return changes.isEmpty ? nil : "已转换；" + changes.joined(separator: "、")
    }
    /// Converts one image. The temporary and destination live in the selected output
    /// directory so that an exclusive hard link can publish without overwriting a file.
    func convert(input: URL, outputDirectory: URL, format: UTType) throws -> URL {
        try Task.checkCancellation()
        guard input.isFileURL, outputDirectory.isFileURL else { throw ImageConversionError.invalidInput }
        guard (Self.allowed.contains(format) || Self.additionalOutputs.contains(format) || format == .pdf), let ext = format.preferredFilenameExtension else { throw ImageConversionError.unsupportedOutput }
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw ImageConversionError.invalidInput }
        if Self.isMultipageTIFF(input) {
            if format == .pdf { return try multipageTIFFToPDF(source: source, input: input, outputDirectory: outputDirectory) }
            if (Self.allowed + Self.additionalOutputs).contains(format) { return try multipageTIFFToImages(source: source, input: input, outputDirectory: outputDirectory, format: format) }
        }
        guard CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageConversionError.invalidInput }
        try Task.checkCancellation()
        let temporary = outputDirectory.appendingPathComponent(".moriq-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        if format == .pdf {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(image.width, image.height)]
            guard let pdfImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ImageConversionError.invalidInput }
            guard let consumer = CGDataConsumer(url: temporary as CFURL) else { throw ImageConversionError.cannotCreateOutput }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            var box = CGRect(origin: .zero, size: Self.pdfPageSize(image: pdfImage, properties: properties))
            guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw ImageConversionError.cannotCreateOutput }
            context.beginPDFPage(nil)
            context.draw(pdfImage, in: box)
            context.endPDFPage()
            context.closePDF()
            guard let document = PDFDocument(url: temporary), document.pageCount == 1, document.page(at: 0) != nil else { throw ImageConversionError.validationFailed }
        } else {
            let available = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
            guard available.contains(format.identifier) else { throw ImageConversionError.unsupportedOutput }
            guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, format.identifier as CFString, 1, nil) else { throw ImageConversionError.cannotCreateOutput }
            let (prepared, properties) = try Self.imageForOutput(source: source, index: 0, original: image, format: format)
            try Task.checkCancellation()
            CGImageDestinationAddImage(destination, prepared, properties)
            guard CGImageDestinationFinalize(destination) else { throw ImageConversionError.encodingFailed }
            guard let check = CGImageSourceCreateWithURL(temporary as CFURL, nil), CGImageSourceCreateImageAtIndex(check, 0, nil) != nil else { throw ImageConversionError.validationFailed }
        }
        try beforePublish()
        let base = input.deletingPathExtension().lastPathComponent
        for suffix in 1...10000 {
            try Task.checkCancellation()
            let name = suffix == 1 ? "\(base).\(ext)" : "\(base) (\(suffix)).\(ext)"
            let target = outputDirectory.appendingPathComponent(name)
            let result = temporary.withUnsafeFileSystemRepresentation { src in target.withUnsafeFileSystemRepresentation { dst in link(src!, dst!) } }
            if result == 0 { return target }
            if errno != EEXIST { throw ImageConversionError.filesystem(errno) }
        }
        throw ImageConversionError.noAvailableName
    }
}
