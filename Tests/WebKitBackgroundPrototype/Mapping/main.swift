import AppKit
import Foundation
import WebKit
import ImageIO
import UniformTypeIdentifiers
let root=URL(fileURLWithPath:"/tmp/moriq-wk-map-probe",isDirectory:true)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
let bitmap=CGContext(data:nil,width:20,height:20,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
bitmap.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));bitmap.fill(CGRect(x:0,y:0,width:20,height:20))
let dest=CGImageDestinationCreateWithURL(root.appendingPathComponent("red.png") as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(dest,bitmap.makeImage()!,nil);precondition(CGImageDestinationFinalize(dest))
for name in ["marked.html", "manifest.json", "element-0.png", "element-1.png"] { try? FileManager.default.removeItem(at:root.appendingPathComponent(name)) }
let id=UUID().uuidString.replacingOccurrences(of:"-",with:"")
let cardHeight = Int(ProcessInfo.processInfo.environment["MORIQ_CARD_HEIGHT"] ?? "50") ?? 50
let cardMargin = Int(ProcessInfo.processInfo.environment["MORIQ_CARD_MARGIN"] ?? "40") ?? 40
let html="""
<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden} p.card{width:200px;height:\(cardHeight)px;background:url(red.png) repeat;margin:0 0 \(cardMargin)px;font:16px/20px Arial}</style></head><body><p id="one" class="card">DUPLICATE TEXT</p><p id="two" class="card">DUPLICATE TEXT</p><script>window.pageScriptRan=true</script></body></html>
"""
let source=root.appendingPathComponent("source.html");try html.write(to:source,atomically:true,encoding:.utf8)
let app=NSApplication.shared
final class Fixture:NSObject,WKNavigationDelegate {
 let root:URL;let identifier:String;var web:WKWebView!
 init(root:URL,identifier:String){self.root=root;self.identifier=identifier}
 func start(_ rules:WKContentRuleList){let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent();config.defaultWebpagePreferences.allowsContentJavaScript=false;config.userContentController.add(rules);web=WKWebView(frame:NSRect(x:0,y:0,width:320,height:240),configuration:config);web.navigationDelegate=self
  if let preparedPath=ProcessInfo.processInfo.environment["MORIQ_MAP_PREPARED_HTML"] {
   let prepared=try! String(contentsOfFile:preparedPath,encoding:.utf8)
   web.loadHTMLString(prepared,baseURL:nil)
  } else { web.loadFileURL(root.appendingPathComponent("source.html"),allowingReadAccessTo:root) }}
 func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){
  Task { @MainActor in
   let js="""
   const nodes=[...document.querySelectorAll('p.card')];
   if(window.pageScriptRan || nodes.length!==2 || document.body.children.length!==nodes.length || nodes.some(n=>n.parentElement!==document.body) || [...document.body.childNodes].some(n=>n.nodeType===Node.TEXT_NODE && n.textContent.trim()!=='')) return JSON.stringify({unsupported:'网页结构不支持，已回退普通转换，元素背景可能丢失'});
   for(const el of document.querySelectorAll('*')) {
    for(const pseudo of ['::before','::after']) if(getComputedStyle(el,pseudo).backgroundImage!=='none') return JSON.stringify({unsupported:'伪元素背景不支持，已回退普通转换，元素背景可能丢失'});
    if(!nodes.includes(el) && getComputedStyle(el).backgroundImage!=='none') return JSON.stringify({unsupported:'其他元素背景不支持，已回退普通转换，元素背景可能丢失'});
   }
   const rects=nodes.map(n=>n.getBoundingClientRect());
   if(rects.some((a,i)=>rects.slice(i+1).some(b=>a.left<b.right && b.left<a.right && a.top<b.bottom && b.top<a.bottom))) return JSON.stringify({unsupported:'重叠元素不支持，已回退普通转换，元素背景可能丢失'});
   const results=[];
   for (let i=0;i<nodes.length;i++) { const n=nodes[i], r=n.getBoundingClientRect(), css=getComputedStyle(n).backgroundImage, m=css.match(/url\\(["']?(.+?)["']?\\)/); if(!m)return JSON.stringify({unsupported:'背景来源不支持，已回退普通转换，元素背景可能丢失'});
     const ok=await new Promise(resolve=>{const img=new Image();img.onload=()=>resolve(true);img.onerror=()=>resolve(false);img.src=m[1];setTimeout(()=>resolve(false),2000)});if(!ok)return JSON.stringify({unsupported:'背景资源缺失，已回退普通转换，元素背景可能丢失'});
     const style=getComputedStyle(n), range=document.createRange();range.selectNodeContents(n);
     const lineHeight=parseFloat(style.lineHeight), marginBottom=parseFloat(style.marginBottom);
     if(n.children.length!==0 || style.position!=='static' || !Number.isFinite(lineHeight) || !Number.isFinite(marginBottom) || range.getClientRects().length!==1 || r.x<0 || r.y<0 || r.right>innerWidth || r.bottom>innerHeight) return JSON.stringify({unsupported:'段落布局不支持，已回退普通转换，元素背景可能丢失'});
     const marker='MQR\(identifier)X'+i+'END';results.push({marker,x:r.x,y:r.y,width:r.width,height:r.height,lineHeight,marginBottom});n.prepend(document.createTextNode(marker)); }
   const marked='<!doctype html>'+document.documentElement.outerHTML;
   for(const e of document.querySelectorAll('*')){e.style.color='transparent';e.style.textShadow='none'}
   return JSON.stringify({marked,results});
   """
   do {
    let result=try await webView.callAsyncJavaScript(js,arguments:[:],in:nil,contentWorld:.page)
    guard let str=result as? String,let data=str.data(using:.utf8),let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{fatalError("invalid fixture result")}
    if let reason=value["unsupported"] as? String { print("FALLBACK \(reason)");fflush(stdout);NSApp.stop(nil);return }
    guard let marked=value["marked"] as? String,let records=value["results"] as? [[String:Any]],records.count==2 else{fatalError("invalid fixture result")}
    try marked.write(to:self.root.appendingPathComponent("marked.html"),atomically:true,encoding:.utf8)
    try JSONSerialization.data(withJSONObject:records,options:.prettyPrinted).write(to:self.root.appendingPathComponent("manifest.json"))
    let config=WKSnapshotConfiguration();config.rect=CGRect(x:0,y:0,width:320,height:240)
    let image=try await webView.takeSnapshot(configuration:config)
    guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else{fatalError("image")}
    let sx=Double(cg.width)/320,sy=Double(cg.height)/240
    for (i,record) in records.enumerated(){guard let x=record["x"] as? Double,let y=record["y"] as? Double,let w=record["width"] as? Double,let h=record["height"] as? Double,let crop=cg.cropping(to:CGRect(x:x*sx,y:y*sy,width:w*sx,height:h*sy)),let out=CGImageDestinationCreateWithURL(self.root.appendingPathComponent("element-\(i).png") as CFURL,UTType.png.identifier as CFString,1,nil) else{fatalError("crop")};CGImageDestinationAddImage(out,crop,nil);guard CGImageDestinationFinalize(out) else{fatalError("save")}}
    print("PASS two identical DOM elements have unique markers and background layers");fflush(stdout);NSApp.stop(nil)
   } catch { fatalError("mapping fixture failed \(error)") }
  }
 }
}
let fixture=Fixture(root:root,identifier:id)
let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file://"},"action":{"type":"block"}}]"#
WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"moriq-map-probe",encodedContentRuleList:rules){list,error in guard let list,error == nil else{fatalError("rules")};fixture.start(list)}
app.run()
