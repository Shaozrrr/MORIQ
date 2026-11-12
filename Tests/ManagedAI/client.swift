import Foundation
import AppKit
@main struct Run {
 static func main() async throws {
    let token = ProcessInfo.processInfo.environment["TEST_ACCOUNT_TOKEN"]!
    let port = ProcessInfo.processInfo.environment["TEST_GATEWAY_PORT"]!
    let local = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
    do { _ = try ManagedAIClient(endpoint: local); fatalError("HTTP not rejected") } catch ManagedAIError.invalidEndpoint {}
    do { _ = try ManagedAIClient(endpoint: URL(string:"https://user:pass@example.com/v1")!); fatalError("credentials in URL accepted") } catch ManagedAIError.invalidEndpoint {}
    let client = try ManagedAIClient(endpoint: local, tokenLoader: { token }, allowLoopbackForTesting: true)
    var text = ""
    try await client.provider().stream(messages: [ChatMessage(role: "user", content: "hello")]) { text += $0 }
    guard text == "hello" else { fatalError("unexpected stream") }
    let direct = AIServiceRouter.provider(configuredValue: nil)
    guard direct.endpoint.host == "api.deepseek.com" else { fatalError("unconfigured service changed default") }
    var leakedToLoader = false
    let invalid = AIServiceRouter.provider(configuredValue: "http://example.invalid/v1/chat/completions", tokenLoader: { leakedToLoader = true; return token })
    do { try await invalid.stream(messages: [ChatMessage(role:"user",content:"test")]) { _ in }; fatalError("invalid configuration accepted") }
    catch ManagedAIError.invalidEndpoint {}
    guard !leakedToLoader else { fatalError("invalid endpoint loaded credentials") }
    let missing = AIServiceRouter.provider(configuredValue: local.absoluteString, tokenLoader: { nil }, allowLoopbackForTesting: true)
    do { try await missing.stream(messages:[ChatMessage(role:"user",content:"test")]) { _ in }; fatalError("missing account accepted") }
    catch ManagedAIError.notSignedIn {}
    let expired = AIServiceRouter.provider(configuredValue: local.absoluteString, tokenLoader: { "invalid-" + String(repeating:"x", count: 40) }, allowLoopbackForTesting: true)
    do { try await expired.stream(messages:[ChatMessage(role:"user",content:"test")]) { _ in }; fatalError("expired account accepted") }
    catch ManagedAIError.sessionExpired {}
    guard AIErrorMessage.describe(ManagedAIError.sessionExpired) == "登录已过期，请重新登录。", AIErrorMessage.describe(ManagedAIError.notSignedIn) == "请先登录 MORIQ 账户。" else { fatalError("account error message") }
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1,pixelsHigh:1,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0), let jpeg = bitmap.representation(using:.jpeg,properties:[:]) else { fatalError("fixture") }
    let routed = AIServiceRouter.provider(configuredValue: local.absoluteString, tokenLoader: { token }, allowLoopbackForTesting: true)
    var answer = ""
    let history = [ChatMessage(role:"user",content:"prior",images:Array(repeating:jpeg,count:11)),ChatMessage(role:"assistant",content:"answer"),ChatMessage(role:"user",content:"current",images:Array(repeating:jpeg,count:11))]
    try await routed.stream(messages:history) { answer += $0 }
    guard answer == "hello" else { fatalError("multi-image stream") }
    let tooMany = (0..<201).map { _ in ChatMessage(role:"user",content:"test") }
    do { try await routed.stream(messages:tooMany) { _ in }; fatalError("unbounded history accepted") }
    catch DeepSeekError.requestTooLarge {}
    do { try await routed.stream(messages:[ChatMessage(role:"user",content:String(repeating:"a", count:250_001))]) { _ in }; fatalError("oversize text accepted") }
    catch DeepSeekError.requestTooLarge {}
    do { try await routed.stream(messages:[ChatMessage(role:"user",content:"test",images:Array(repeating:jpeg,count:12))]) { _ in }; fatalError("too many images accepted") }
    catch DeepSeekError.requestTooLarge {}
    do { try await routed.stream(messages:[ChatMessage(role:"user",content:"__fail__")]) { _ in }; fatalError("upstream error accepted") }
    catch DeepSeekError.http(502) {}
    let slow = Task { try await routed.stream(messages:[ChatMessage(role:"user",content:"__slow__")]) { _ in } }
    try await Task.sleep(for: .milliseconds(400))
    let stoppedAt = Date(); slow.cancel()
    do { try await slow.value; fatalError("cancelled request completed") }
    catch is CancellationError {}
    catch let error as URLError where error.code == .cancelled {}
    guard Date().timeIntervalSince(stoppedAt) < 2 else { fatalError("cancellation too slow") }
    let redirectPort = ProcessInfo.processInfo.environment["TEST_REDIRECT_PORT"]!
    let redirect = try ManagedAIClient(endpoint: URL(string:"http://127.0.0.1:\(redirectPort)/redirect")!, tokenLoader: { token }, allowLoopbackForTesting: true)
    do { try await redirect.provider().stream(messages: [ChatMessage(role:"user", content:"hello")]) { _ in }; fatalError("redirect accepted") }
    catch DeepSeekError.http(302) {}
    print("PASS managed client SSE and loopback-only test exception")
 }
}
