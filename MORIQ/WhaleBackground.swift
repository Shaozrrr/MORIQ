import SwiftUI
import WebKit

/// Only the locally bundled character animation is rendered in WebKit; all
/// controls and permission handling remain native SwiftUI/AppKit.
struct WhaleBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.underPageBackgroundColor = .clear
        view.setValue(false, forKey: "drawsBackground")
        if let url = Bundle.main.url(forResource: "WhaleBackground", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            view.loadHTMLString(html, baseURL: nil)
        }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
