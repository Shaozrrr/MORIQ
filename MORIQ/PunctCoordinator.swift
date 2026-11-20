import Foundation
// Isolated adapter; the owner must close the transport on `false`.
struct PunctCoordinator {
 var verifier: SourceV2Verifier
 private var terminal: (UInt64,String,[[String:Any]],[[String:Int]],[String:Any])?
 private(set) var completed=false
 var awaitingFinished: Bool { terminal != nil }
 mutating func batch(seq:UInt64,confirmed:String,units:[[String:Any]],ranges:[[String:Int]],coverage:[String:Any],negotiated:Bool)->Bool {
  guard !completed, terminal == nil, let state=coverage["state"] as? String else{return false}
  if state == "complete" {
   // Validate tentatively, but don't mutate the live verifier before finished.
   var trial=verifier
   guard trial.punctBatch(seq,confirmed:confirmed,units:units,ranges:ranges,coverage:coverage,finished:true,negotiated:negotiated) else{return false}
   terminal=(seq,confirmed,units,ranges,coverage);return true
  }
  guard state == "open" else{return false}
  return verifier.punctBatch(seq,confirmed:confirmed,units:units,ranges:ranges,coverage:coverage,finished:false,negotiated:negotiated)
 }
 mutating func finish(negotiated:Bool)->Bool {
  guard !completed, let (seq,text,units,ranges,coverage)=terminal,
        verifier.punctBatch(seq,confirmed:text,units:units,ranges:ranges,coverage:coverage,finished:true,negotiated:negotiated) else{return false}
  terminal=nil;completed=true;return true
 }
 mutating func disconnected(){terminal=nil}
}
