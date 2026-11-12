import AppKit
import SwiftUI
@MainActor enum InteractionFeedback { static func confirmation() {} }
enum DeepSeekError: Error { case invalidResponse }
struct ChatMessage { init(role: String, content: String, images: [Data]) {} }
struct DeepSeekProvider { func stream(messages: [ChatMessage], onDelta: @escaping (String) -> Void) async throws {} }
enum AIErrorMessage { static func describe(_ error: Error) -> String { "ERROR" } }
struct ChatResponseView: View { let content:String; var body: some View { Text(content) } }
@MainActor final class ScreenshotPinManager { static let shared = ScreenshotPinManager(); func show(_ image: CGImage) {} }
