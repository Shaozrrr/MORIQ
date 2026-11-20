import Foundation
import AppKit

@main struct CandidateClient {
 static func main() async throws {
  let env = ProcessInfo.processInfo.environment
  let url = URL(string: "http://127.0.0.1:\(env["TEST_GATEWAY_PORT"]!)/v1/chat/completions")!
  let token = env["TEST_ACCOUNT_TOKEN"]!
  let provider = try ManagedAIClient(endpoint: url, tokenLoader: { token }, allowLoopbackForTesting: true).provider()
  guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0), let jpeg = bitmap.representation(using:.jpeg,properties:[:]) else { fatalError("fixture") }
  let first = ChatMessage(role:"user",content:"first",images:[jpeg])
  var answer = ""
  try await provider.stream(messages:[first]) { answer += $0 }
  guard answer == "hello" else { fatalError("first response") }
  if env["MORIQ_SINGLE_PROBE"] == "1" { print("PASS Swift single probe"); return }
  answer = ""
  let history = [first,ChatMessage(role:"assistant",content:"hello"),ChatMessage(role:"user",content:"compare",images:[jpeg])]
  try await provider.stream(messages:history) { answer += $0 }
  guard answer == "hello" else { fatalError("second response") }
  print("PASS Swift client two-turn candidate")
 }
}
