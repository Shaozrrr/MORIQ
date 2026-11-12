import Foundation
import AppKit
import ImageIO
final class CaptureProtocol: URLProtocol {
 static var body: Data?
 override class func canInit(with request: URLRequest) -> Bool { true }
 override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
 override func startLoading() {
  Self.body = request.httpBody
  if Self.body == nil, let input = request.httpBodyStream {
   input.open(); defer { input.close() }; var bytes = [UInt8](repeating: 0, count: 4096); var data = Data()
   while input.hasBytesAvailable { let n = input.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(bytes, count: n) }
   Self.body = data
  }
  let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
  client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
  client?.urlProtocol(self, didLoad: Data((#"data: {"choices":[{"delta":{"content":"好的"}}]}"# + "\n\ndata: [DONE]\n\n").utf8)); client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading() {}
}
@main struct Run {
 static func main() async throws {
  let context = CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
  let edited = ScreenshotAnnotationRenderer.render(context.makeImage()!, annotations: [.redact(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))])!
  let encoded = ScreenshotAIImage.encode(edited)!
  let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CaptureProtocol.self]
  let provider = DeepSeekProvider(session: URLSession(configuration: config), endpoint: URL(string: "https://example.invalid")!, keyLoader: { "test-key" })
  try await provider.stream(messages: [ChatMessage(role: "user", content: "图片里是什么？", images: [encoded])]) { _ in }
  let body = try JSONSerialization.jsonObject(with: CaptureProtocol.body!) as! [String: Any]
  let message = (body["messages"] as! [[String: Any]])[0]
  let parts = message["content"] as! [[String: Any]]
  let url = ((parts[1]["image_url"] as! [String: String])["url"])!
  precondition(url.hasPrefix("data:image/jpeg;base64,"))
  let bytes = Data(base64Encoded: String(url.dropFirst("data:image/jpeg;base64,".count)))!
  guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("jpeg invalid") }
  let bitmap = NSBitmapImageRep(cgImage: decoded)
  let center = bitmap.colorAt(x: 80, y: 60)!.usingColorSpace(.deviceRGB)!
  let corner = bitmap.colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!
  precondition(center.redComponent < 0.05 && corner.redComponent > 0.95)
  precondition(parts[0]["text"] as? String == "图片里是什么？")
  let large = CGContext(data: nil, width: 8200, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  large.setFillColor(CGColor(gray: 1, alpha: 1)); large.fill(CGRect(x: 0, y: 0, width: 8200, height: 40))
  let masked = ScreenshotAnnotationRenderer.render(large.makeImage()!, annotations: [.redact(CGRect(x: 0.25, y: 0, width: 0.5, height: 1))])!
  let largeData = ScreenshotAIImage.encode(masked)!
  let largeSource = CGImageSourceCreateWithData(largeData as CFData, nil)!
  let largeImage = CGImageSourceCreateImageAtIndex(largeSource, 0, nil)!
  precondition(largeImage.width == 8192 && largeImage.height <= 40)
  let centerPixel = NSBitmapImageRep(cgImage: largeImage).colorAt(x: largeImage.width / 2, y: largeImage.height / 2)!.usingColorSpace(.deviceRGB)!
  precondition(centerPixel.redComponent < 0.05)
  print("PASS edited image sent as JPEG and redaction remains opaque")
 }
}
