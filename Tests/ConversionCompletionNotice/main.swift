import Foundation
let input=URL(fileURLWithPath:"/tmp/source.html"), output=URL(fileURLWithPath:"/tmp/result.docx")
let fidelity=DocumentConverter.pdfResultNotice(input:input,targetExtension:"docx")!
let success=ConversionRecord(source:input,output:output,message:fidelity)
let failure=ConversionRecord(source:input,output:nil,message:"转换失败：资源不可读")
precondition(ConversionRecord.completionNotice([success],requestedCount:1,archive:false).contains("背景图"))
precondition(ConversionRecord.completionNotice([failure],requestedCount:1,archive:false)==failure.message)
precondition(ConversionRecord.completionNotice([success,success],requestedCount:2,archive:false).contains("转换记录"))
precondition(ConversionRecord.completionNotice([success,failure],requestedCount:2,archive:false).contains("失败 1 项"))
precondition(ConversionRecord.completionNotice([success],requestedCount:3,archive:true)==fidelity)
print("PASS single conversion displays fidelity or error; batch points to conversion records")
