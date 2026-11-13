import Foundation
import FluidAudio
@main struct Main {
 static func main() async throws {
  let embedder = try await CampPlusEmbedder.load()
  var values = [[Float]]()
  for path in CommandLine.arguments.dropFirst() { values.append(try await embedder.embed(audioURL: URL(fileURLWithPath:path))) }
  for i in 0..<values.count { for j in (i+1)..<values.count { print("\(i) \(j) \(CampPlusEmbedder.cosine(values[i],values[j]))") } }
 }
}
