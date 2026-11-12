import AppKit
import Foundation
import WebKit
import ImageIO
import UniformTypeIdentifiers

let app = NSApplication.shared
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MORIQ_WK_PROBE_DIR"] ?? "/tmp/moriq-wk-background-probe", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let colorspace = CGColorSpaceCreateDeviceRGB()
let imageContext = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: colorspace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
imageContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); imageContext.fill(CGRect(x:0,y:0,width:20,height:20))
imageContext.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); imageContext.fill(CGRect(x:20,y:0,width:20,height:20))
let target = CGImageDestinationCreateWithURL(root.appendingPathComponent("tile.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(target, imageContext.makeImage()!, nil); precondition(CGImageDestinationFinalize(target))
let outside = root.deletingLastPathComponent().appendingPathComponent("moriq-wk-probe-outside.png")
try? FileManager.default.removeItem(at: outside)
try FileManager.default.copyItem(at: root.appendingPathComponent("tile.png"), to: outside)
let escape = root.appendingPathComponent("escape.png")
try? FileManager.default.removeItem(at: escape)
try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
// Only a synthetic in-memory allowlist is exposed to WebKit. File and network
// schemes are blocked; this prototype does not yet parse arbitrary user HTML.
let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file://"},"action":{"type":"block"}}]"#
final class Assets:NSObject,WKURLSchemeHandler {
 let tile:Data
 init(tile:Data){self.tile=tile}
 func webView(_ webView:WKWebView,start task:WKURLSchemeTask){
  guard let url=task.request.url,url.scheme=="moriqasset",url.host=="fixture",url.path=="/tile.png",url.query==nil else {task.didFailWithError(NSError(domain:"MORIQProbe",code:404));return}
  task.didReceive(URLResponse(url:url,mimeType:"image/png",expectedContentLength:tile.count,textEncodingName:nil));task.didReceive(tile);task.didFinish()
 }
 func webView(_ webView:WKWebView,stop task:WKURLSchemeTask){}
}
final class Probe: NSObject, WKNavigationDelegate {
 let root: URL; var view: WKWebView!; var index = 0; var assets:Assets!
 let cases: [(String,String)] = [("repeat", "url(tile.png) repeat 0px 0px"), ("cover", "url(tile.png) no-repeat center center / cover"), ("missing", "url(absent-resource-file.png) no-repeat"), ("remote", "url(http://127.0.0.1:47601/probe.png) no-repeat"), ("element", "none"), ("elementmissing", "none"), ("multilayer", "none"), ("pagination", "none"), ("symlink", "url(escape.png) no-repeat"), ("outside", "url(file:///tmp/moriq-wk-probe-outside.png) no-repeat")]
 init(root: URL) { self.root = root }
 func begin(rule: WKContentRuleList) {
  let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
  configuration.defaultWebpagePreferences.allowsContentJavaScript = false
  configuration.userContentController.add(rule)
  assets = Assets(tile:try! Data(contentsOf:root.appendingPathComponent("tile.png")))
  configuration.setURLSchemeHandler(assets,forURLScheme:"moriqasset")
  view = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
  view.navigationDelegate = self
  next()
 }
 func next() {
  guard index < cases.count else { print("PASS WebKit background prototype"); fflush(stdout); NSApp.stop(nil); return }
  let (name, background) = cases[index]
  let extraCSS: String
  switch name {
  case "element": extraCSS = "#card{position:absolute;left:60px;top:50px;width:120px;height:80px;background:url(tile.png) repeat}"
  case "elementmissing": extraCSS = "#card{position:absolute;left:60px;top:50px;width:120px;height:80px;background:url(absent-resource-file.png) no-repeat}"
  case "multilayer": extraCSS = "#card{position:absolute;left:60px;top:50px;width:120px;height:80px;background-image:url(tile.png),url(absent-resource-file.png)}"
  case "pagination": extraCSS = "html,body{height:auto;min-height:720px;overflow:auto}#card{position:absolute;left:60px;top:300px;width:120px;height:80px;background:url(tile.png) repeat}"
  default: extraCSS = ""
  }
  let html = """
  <!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden}body{background:\(background)}p{font:20px sans-serif}\(extraCSS)</style></head><body><p>EDITABLE TEXT 4812</p><div id="card">CARD TEXT</div><script>window.userScriptRan = true</script></body></html>
  """
  let path = root.appendingPathComponent("\(name).html")
  do { try html.write(to: path, atomically: true, encoding: .utf8) } catch { fatalError("write: \(error)") }
  view.loadHTMLString(html,baseURL:URL(string:"moriqasset://fixture/")!)
 }
 func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
  let name = cases[index].0
  let script = """
    const urls = [];
    const re = /url\\((?:"([^"]*)"|'([^']*)'|([^)]*))\\)/g;
    for (const el of document.querySelectorAll('*')) {
      for (const pseudo of [null, '::before', '::after']) {
        const bg = getComputedStyle(el, pseudo).backgroundImage;
        for (const match of bg.matchAll(re)) urls.push((match[1] ?? match[2] ?? match[3]).trim());
      }
      if (el.tagName === 'IMG' && el.currentSrc) urls.push(el.currentSrc);
    }
    const unique = [...new Set(urls)];
    const checks = await Promise.all(unique.map(src => new Promise(resolve => {
      const image = new Image(); image.onload=()=>resolve({src, ok:true}); image.onerror=()=>resolve({src, ok:false}); image.src=src;
      setTimeout(()=>resolve({src, ok:false}), 2500);
    })));
    const text = document.body.innerText;
    for (const e of document.querySelectorAll('*')) { e.style.color='transparent'; e.style.textShadow='none'; }
    return JSON.stringify({script: !!window.userScriptRan, text, checks});
  """
  Task { @MainActor in
   let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
   guard let text = result as? String, let data = text.data(using:.utf8), let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { fatalError("evaluation failed") }
   guard object["script"] as? Bool == false, (object["text"] as? String)?.contains("EDITABLE TEXT 4812") == true else { fatalError("script ran or text lost") }
   let expected = ["repeat", "cover", "element", "pagination"].contains(name)
   guard let checks = object["checks"] as? [[String:Any]], !checks.isEmpty,
         checks.allSatisfy({ $0["ok"] as? Bool == true }) == expected else { fatalError("resource detection \(name): \(object)") }
   if name == "multilayer" { guard checks.count == 2, checks.contains(where: { $0["ok"] as? Bool == true }), checks.contains(where: { $0["ok"] as? Bool == false }) else { fatalError("multi-layer check incomplete") } }
   let config = WKSnapshotConfiguration(); config.rect = CGRect(x:0,y:0,width:320,height:240)
   webView.takeSnapshot(with: config) { image,error in
    guard error == nil, let image, let tiff=image.tiffRepresentation, let rep=NSBitmapImageRep(data:tiff), let png=rep.representation(using:.png,properties:[:]) else { fatalError("snapshot failed \(String(describing:error))") }
    do { try png.write(to:self.root.appendingPathComponent("snapshot-\(name).png")) } catch { fatalError("save: \(error)") }
    if name == "pagination" {
     Task { @MainActor in
      let result = try await webView.callAsyncJavaScript("window.scrollTo(0,240); return {y:window.scrollY,total:document.documentElement.scrollHeight};", arguments: [:], in: nil, contentWorld: .page)
      guard let values = result as? [String:Any], let y = values["y"] as? Int, y == 240, let total = values["total"] as? Int, total >= 720 else { fatalError("scroll pagination failed \(String(describing:result))") }
      webView.takeSnapshot(with: config) { image, error in
       guard error == nil, let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff), let png = rep.representation(using:.png,properties:[:]) else { fatalError("second viewport snapshot failed") }
       try! png.write(to:self.root.appendingPathComponent("snapshot-pagination-2.png"))
       print("PASS pagination: scrollY=\(y), height=\(total), second viewport captured"); fflush(stdout)
       self.index += 1; self.next()
      }
     }
    } else {
     print("PASS \(name): script blocked, text retained, resources loaded=\(expected)"); fflush(stdout)
     self.index += 1; self.next()
    }
   }
  }
 }
 func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fatalError("navigation \(error)") }
}
let probe = Probe(root: root)
WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "moriq-probe-no-network", encodedContentRuleList: rules) { list,error in
 guard let list, error == nil else { fatalError("content rule compilation \(String(describing:error))") }
 probe.begin(rule:list)
}
app.run()
