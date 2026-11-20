import Foundation
import Darwin

enum DiagnosticFeature: String, Codable, CaseIterable {
    case startup, onboarding, permissions, shortcuts, settings, conversion, assistant, shelf, clipboard, screenshot, notes, captions
    var label: String { switch self {
    case .startup: "启动"; case .onboarding: "引导"; case .permissions: "权限"; case .shortcuts: "快捷键"; case .settings: "设置"
    case .conversion: "转换"; case .assistant: "助手"; case .shelf: "暂存架"; case .clipboard: "剪贴板"; case .screenshot: "截图"; case .notes: "便签"; case .captions: "字幕"
    }}
}
enum DiagnosticAction: String, Codable { case launch, open, start, complete, cancel, copy, check, select, toggle, recognize, translate, favorite, add, remove, drag, save, close, firstOutput, disconnect, waiting, foreground, reconnect, stop, teardown }
enum DiagnosticOutcome: String, Codable { case started, success, failure, cancelled }
enum DiagnosticFormat: String, Codable { case image, pdf, document, spreadsheet, presentation, audio, video, archive, text, mixed, other
    static func fromExtension(_ value: String) -> Self {
        switch value.lowercased() {
        case "png","jpg","jpeg","heic","heif","webp","gif","bmp","tif","tiff","avif": return .image
        case "pdf": return .pdf
        case "doc","docx","odt","rtf": return .document
        case "xls","xlsx","ods","csv": return .spreadsheet
        case "ppt","pptx","odp": return .presentation
        case "mp3","wav","m4a","aac","flac","ogg","opus","aiff": return .audio
        case "mp4","mov","mkv","webm","avi","m4v": return .video
        case "zip","7z","tar","gz","tgz","bz2","xz": return .archive
        case "txt","md","html","htm": return .text
        default: return .other
        }
    }
}
// *Accepted means the model accepted data, not that pixels were presented.
// captionStop distinguishes a user stop request from an internal teardown;
// neither reports completion. captionConnectionAndSetup spans ready plus local
// configuration, and is not an exact handshake or pixel presentation metric.
enum DiagnosticStage: String, Codable { case convert, permissionFolder, permissionScreen, permissionAccessibility, permissionAudio, permissionForeground, captionCapture, captionWSS, captionConnectionAndSetup, captionOriginalAccepted, captionTranslationAccepted, captionReconnect, captionStop }
enum DiagnosticProtocol: String, Codable { case managedSpeechV1 }
enum DiagnosticError: String, Codable { case unknown, storage, diskFull, permissionDenied, unsupported, invalidInput, invalidOutput, conflict, unavailable, engine, mixed }
enum DiagnosticCountBucket: String, Codable { case zero, one, twoToFive, sixToTwenty, overTwenty
    static func from(_ n:Int) -> Self { n <= 0 ? .zero : n == 1 ? .one : n <= 5 ? .twoToFive : n <= 20 ? .sixToTwenty : .overTwenty }
}
enum DiagnosticDurationBucket: String, Codable { case under100ms, under500ms, under2s, under10s, over10s
    static func from(_ seconds:Double) -> Self? {
        guard seconds.isFinite, seconds >= 0 else{return nil}
        return seconds < 0.1 ? .under100ms : seconds < 0.5 ? .under500ms : seconds < 2 ? .under2s : seconds < 10 ? .under10s : .over10s
    }
}
struct DiagnosticEvent: Codable {
    let version: Int
    let day: Int
    let feature: DiagnosticFeature
    let action: DiagnosticAction
    let outcome: DiagnosticOutcome
    let durationBucket: DiagnosticDurationBucket?
    let operationID: UUID
    var inputFormat: DiagnosticFormat?
    var outputFormat: DiagnosticFormat?
    var stage: DiagnosticStage?
    var error: DiagnosticError?
    var countBucket: DiagnosticCountBucket?
    var runID: UUID? = nil
    var buildNumber: UInt? = nil
    var protocolVersion: DiagnosticProtocol? = nil
    var sequence: UInt64? = nil
    var monotonic100ms: UInt64? = nil
    // Locally generated per session/connection; not provider IDs or stable installation IDs.
    var captionSession: UUID? = nil
    var captionEpoch: UUID? = nil
    init(day:Int, feature:DiagnosticFeature, action:DiagnosticAction, outcome:DiagnosticOutcome, durationBucket:DiagnosticDurationBucket?, operationID:UUID, inputFormat:DiagnosticFormat?=nil, outputFormat:DiagnosticFormat?=nil, stage:DiagnosticStage?=nil, error:DiagnosticError?=nil, countBucket:DiagnosticCountBucket?=nil) {
        version=1;self.day=day;self.feature=feature;self.action=action;self.outcome=outcome;self.durationBucket=durationBucket;self.operationID=operationID;self.inputFormat=inputFormat;self.outputFormat=outputFormat;self.stage=stage;self.error=error;self.countBucket=countBucket
    }
    enum CodingKeys: String, CodingKey {case version,day,feature,action,outcome,durationBucket,durationMs,operationID,inputFormat,outputFormat,stage,error,countBucket,runID,buildNumber,protocolVersion,sequence,monotonic100ms,captionSession,captionEpoch}
    init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        let v=try c.decode(Int.self,forKey:.version)
        guard v == 1 else {throw DecodingError.dataCorruptedError(forKey:.version,in:c,debugDescription:"Unsupported diagnostic schema version")}
        version=v;day=try c.decode(Int.self,forKey:.day);feature=try c.decode(DiagnosticFeature.self,forKey:.feature);action=try c.decode(DiagnosticAction.self,forKey:.action);outcome=try c.decode(DiagnosticOutcome.self,forKey:.outcome)
        let existingBucket=try c.decodeIfPresent(DiagnosticDurationBucket.self,forKey:.durationBucket)
        var legacyBucket: DiagnosticDurationBucket? = nil
        // Swift's synthesized encoder omitted nil, but accept explicit null
        // conservatively as "no duration" for externally written v1 files.
        if c.contains(.durationMs) {
            if try !c.decodeNil(forKey:.durationMs) {
                let ms=try c.decode(Int64.self,forKey:.durationMs)
                guard ms >= 0 && ms <= 86_400_000 else {throw DecodingError.dataCorruptedError(forKey:.durationMs,in:c,debugDescription:"Invalid legacy duration")}
                legacyBucket=DiagnosticDurationBucket.from(Double(ms)/1000)
            }
        }
        durationBucket=existingBucket ?? legacyBucket
        operationID=try c.decode(UUID.self,forKey:.operationID)
        inputFormat=try c.decodeIfPresent(DiagnosticFormat.self,forKey:.inputFormat);outputFormat=try c.decodeIfPresent(DiagnosticFormat.self,forKey:.outputFormat);stage=try c.decodeIfPresent(DiagnosticStage.self,forKey:.stage);error=try c.decodeIfPresent(DiagnosticError.self,forKey:.error);countBucket=try c.decodeIfPresent(DiagnosticCountBucket.self,forKey:.countBucket)
        runID=try c.decodeIfPresent(UUID.self,forKey:.runID);buildNumber=try c.decodeIfPresent(UInt.self,forKey:.buildNumber);protocolVersion=try c.decodeIfPresent(DiagnosticProtocol.self,forKey:.protocolVersion);sequence=try c.decodeIfPresent(UInt64.self,forKey:.sequence);monotonic100ms=try c.decodeIfPresent(UInt64.self,forKey:.monotonic100ms);captionSession=try c.decodeIfPresent(UUID.self,forKey:.captionSession);captionEpoch=try c.decodeIfPresent(UUID.self,forKey:.captionEpoch)
    }
    func encode(to encoder: Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(version,forKey:.version);try c.encode(day,forKey:.day);try c.encode(feature,forKey:.feature);try c.encode(action,forKey:.action);try c.encode(outcome,forKey:.outcome);try c.encodeIfPresent(durationBucket,forKey:.durationBucket);try c.encode(operationID,forKey:.operationID)
        try c.encodeIfPresent(inputFormat,forKey:.inputFormat);try c.encodeIfPresent(outputFormat,forKey:.outputFormat);try c.encodeIfPresent(stage,forKey:.stage);try c.encodeIfPresent(error,forKey:.error);try c.encodeIfPresent(countBucket,forKey:.countBucket);try c.encodeIfPresent(runID,forKey:.runID);try c.encodeIfPresent(buildNumber,forKey:.buildNumber);try c.encodeIfPresent(protocolVersion,forKey:.protocolVersion);try c.encodeIfPresent(sequence,forKey:.sequence);try c.encodeIfPresent(monotonic100ms,forKey:.monotonic100ms);try c.encodeIfPresent(captionSession,forKey:.captionSession);try c.encodeIfPresent(captionEpoch,forKey:.captionEpoch)
    }
}

final class LocalDiagnostics: @unchecked Sendable {
    static let shared: LocalDiagnostics = {
        #if DEBUG
        if let path=ProcessInfo.processInfo.environment["MORIQ_DIAGNOSTICS_TEST_FILE"], !path.isEmpty {
            let suite=ProcessInfo.processInfo.environment["MORIQ_DIAGNOSTICS_TEST_SUITE"].flatMap {UserDefaults(suiteName:$0)} ?? .standard
            return LocalDiagnostics(defaults:suite,file:URL(fileURLWithPath:path))
        }
        #endif
        return LocalDiagnostics()
    }()
    static let enabledKey = "moriq.localDiagnostics.enabled"
    private let defaults: UserDefaults, file: URL
    private let queue = DispatchQueue(label: "local.moriq.diagnostics", qos: .utility)
    private let lock = NSLock()
    private let maxBytes: Int, retentionDays: Int
    private let runID=UUID(), runStart=ProcessInfo.processInfo.systemUptime
    private let buildNumber=(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String).flatMap(UInt.init)
    private var sequence:UInt64=0
    private var pending = [DiagnosticEvent]()
    private var scheduled = false
    private var dropped = 0, writeFailures = 0, capacityEvictions = 0
    #if DEBUG
    var testBeforeWrite: (() -> Void)?
    var testForceRenameFailure = false
    var testFailAfterBytes: Int?
    #endif
    private var maintenance: DispatchSourceTimer?
    init(defaults: UserDefaults = .standard, file: URL? = nil, maxBytes: Int = 524_288, retentionDays: Int = 7) {
        #if !DEBUG
        // The release UI no longer exposes diagnostics controls. Stop any
        // previously enabled local recording without deleting existing data.
        defaults.set(false, forKey: Self.enabledKey)
        #endif
        self.defaults=defaults
        self.file=file ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("MORIQ/diagnostics/events.jsonl")
        self.maxBytes=maxBytes; self.retentionDays=retentionDays
        let timer=DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now(), repeating:.seconds(43_200))
        timer.setEventHandler { [weak self] in self?.prune() };maintenance=timer;timer.resume()
    }
    deinit { maintenance?.cancel() }
    // Resolve each directory using descriptor-relative no-follow operations.
    private func openDirectory(create: Bool) -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        let parts=file.deletingLastPathComponent().standardizedFileURL.path.split(separator:"/").map(String.init)
        for part in parts {
            var next=openat(fd,part,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && create && errno == ENOENT {
                guard mkdirat(fd,part,0o700) == 0 || errno == EEXIST else { close(fd);return -1 }
                next=openat(fd,part,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(fd);guard next >= 0 else {return -1};fd=next
        }
        var directoryInfo=stat()
        guard fstat(fd,&directoryInfo)==0, directoryInfo.st_uid==getuid(), (directoryInfo.st_mode & 0o077)==0 else {close(fd);return -1}
        return fd
    }
    private func readFile(_ dir:Int32) -> Data? {
        let fd=openat(dir,file.lastPathComponent,O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {return nil};defer{close(fd)}
        var info=stat();guard fstat(fd,&info)==0, (info.st_mode & S_IFMT)==S_IFREG, info.st_uid==getuid(), info.st_nlink==1, (info.st_mode & 0o077)==0, info.st_size <= maxBytes else {return nil}
        return try? FileHandle(fileDescriptor:fd,closeOnDealloc:false).readToEnd()
    }
    private func renameTemporary(_ dir:Int32,_ name:String) -> Bool {
        #if DEBUG
        if testForceRenameFailure {return false}
        #endif
        return renameat(dir,name,dir,file.lastPathComponent)==0
    }
    private func prune() {
        let dir=openDirectory(create:false);guard dir>=0 else{return};defer{close(dir)}
        guard let previous=readFile(dir) else{return}
        let today=Int(Date().timeIntervalSince1970/86_400),decoder=JSONDecoder()
        var hasUnknownRecord=false
        var lines=previous.split(separator:10).compactMap { item -> Data? in
            guard let event=try? decoder.decode(DiagnosticEvent.self,from:Data(item)) else {hasUnknownRecord=true;return nil}
            guard event.day <= today,today-event.day < retentionDays else {return nil}
            if let raw=try? JSONSerialization.jsonObject(with:Data(item)) as? [String:Any],raw.keys.contains("durationMs") {
                do {return try JSONEncoder().encode(event)} catch {hasUnknownRecord=true;return nil}
            }
            return Data(item)
        }
        // Preserve unknown or corrupt records for explicit user review/clear;
        // older builds must not silently erase a future schema.
        guard !hasUnknownRecord else{return}
        var size=lines.reduce(0){$0+$1.count+1};while size>maxBytes && !lines.isEmpty {size -= lines.removeFirst().count+1}
        var output=Data();for line in lines {output.append(line);output.append(10)}
        guard output != previous else{return}
        let name=".events-"+UUID().uuidString
        let temp=openat(dir,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard temp>=0 else{return}
        let wrote=writeAll(temp,output);close(temp)
        if !wrote || !renameTemporary(dir,name) { _ = unlinkat(dir,name,0) }
    }
    private func writeAll(_ fd:Int32,_ data:Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset=0
            while offset<raw.count {
                #if DEBUG
                if let limit=testFailAfterBytes, offset>=limit {return false}
                let remaining=testFailAfterBytes.map {min(raw.count-offset,max(0,$0-offset))} ?? (raw.count-offset)
                #else
                let remaining=raw.count-offset
                #endif
                if remaining == 0 {return false}
                let n=write(fd,raw.baseAddress!.advanced(by:offset),remaining)
                if n<=0{return false};offset+=n
            }
            return true
        }
    }
    func record(_ feature: DiagnosticFeature, _ action: DiagnosticAction, _ outcome: DiagnosticOutcome, duration: TimeInterval? = nil, operationID: UUID = UUID(), inputFormat: DiagnosticFormat? = nil, outputFormat: DiagnosticFormat? = nil, stage: DiagnosticStage? = nil, error: DiagnosticError? = nil, countBucket: DiagnosticCountBucket? = nil, protocolVersion: DiagnosticProtocol? = nil, captionSession: UUID? = nil, captionEpoch: UUID? = nil) {
        guard defaults.bool(forKey:Self.enabledKey) else{return}
        let bucket=duration.flatMap { DiagnosticDurationBucket.from($0) }
        var event=DiagnosticEvent(day:Int(Date().timeIntervalSince1970/86_400),feature:feature,action:action,outcome:outcome,durationBucket:bucket,operationID:operationID,inputFormat:inputFormat,outputFormat:outputFormat,stage:stage,error:error,countBucket:countBucket)
        lock.lock();guard defaults.bool(forKey:Self.enabledKey) else{lock.unlock();return}
        guard pending.count<256 else{dropped+=1;lock.unlock();return}
        sequence &+= 1; event.runID=runID;event.buildNumber=buildNumber;event.protocolVersion=protocolVersion;event.sequence=sequence
        event.monotonic100ms=UInt64(max(0,ProcessInfo.processInfo.systemUptime-runStart)*10)
        event.captionSession=captionSession;event.captionEpoch=captionEpoch
        pending.append(event)
        if !scheduled {scheduled=true;queue.asyncAfter(deadline:.now()+0.05) { [weak self] in self?.drain() }}
        lock.unlock()
    }
    private func drain() {
        lock.lock();let batch=pending;pending.removeAll();scheduled=false;lock.unlock()
        guard defaults.bool(forKey:Self.enabledKey),!batch.isEmpty else{return}
        #if DEBUG
        testBeforeWrite?()
        #endif
        guard defaults.bool(forKey:Self.enabledKey) else{return}
        var succeeded = false
        defer { if !succeeded {lock.lock();writeFailures += batch.count;lock.unlock()} }
        let dir=openDirectory(create:true);guard dir>=0 else{return};defer{close(dir)}
        let fd=openat(dir,file.lastPathComponent,O_RDWR|O_APPEND|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else{return};defer{close(fd)}
        var info=stat();guard fstat(fd,&info)==0,(info.st_mode & S_IFMT)==S_IFREG,info.st_uid==getuid(),info.st_nlink==1,(info.st_mode & 0o077)==0 else{return}
        if info.st_size > 0 {
            var tail: UInt8 = 0
            guard pread(fd,&tail,1,info.st_size-1)==1, tail==10 else {return}
        }
        var output=Data();for event in batch {if let data=try? JSONEncoder().encode(event) {output.append(data);output.append(10)}}
        guard defaults.bool(forKey:Self.enabledKey) else{succeeded=true;return}
        if info.st_size + Int64(output.count) <= Int64(maxBytes) {
            succeeded = writeAll(fd,output)
            if !succeeded { _ = ftruncate(fd,info.st_size) }
        }
        else {
            guard let existing=readFile(dir) else {return}
            // Do not rotate away unknown schemas or damaged records.
            guard existing.split(separator:10).allSatisfy({(try? JSONDecoder().decode(DiagnosticEvent.self,from:Data($0))) != nil}) else {return}
            var lines=(existing+output).split(separator:10).map(Data.init)
            var size=lines.reduce(0){$0+$1.count+1}; var evicted=0
            while size>maxBytes && !lines.isEmpty {size -= lines.removeFirst().count+1;evicted += 1}
            var replacement=Data();for line in lines {replacement.append(line);replacement.append(10)}
            let name=".events-"+UUID().uuidString
            let temp=openat(dir,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
            guard temp>=0 else{return}
            let wrote=writeAll(temp,replacement);close(temp)
            if wrote && renameTemporary(dir,name) {succeeded=true;lock.lock();capacityEvictions += evicted;lock.unlock()} else { _ = unlinkat(dir,name,0) }
        }
    }
    func health() -> (dropped:Int, writeFailures:Int, capacityEvictions:Int) { lock.lock();defer{lock.unlock()};return (dropped,writeFailures,capacityEvictions) }
    func summary(_ completion: @escaping ([DiagnosticFeature:Int]) -> Void) {
        queue.async { [self] in
            let dir=openDirectory(create:false);var counts=[DiagnosticFeature:Int]()
            if dir>=0 {
                if let data=readFile(dir) {for line in data.split(separator:10) {if let event=try? JSONDecoder().decode(DiagnosticEvent.self,from:Data(line)) {counts[event.feature,default:0]+=1}}}
                close(dir)
            }
            DispatchQueue.main.async {completion(counts)}
        }
    }
    func clear(_ completion: @escaping (Bool) -> Void) {
        lock.lock();pending.removeAll();lock.unlock()
        queue.async { [self] in
            let dir=openDirectory(create:false);var success=false
            if dir>=0 {
                var info=stat()
                if fstatat(dir,file.lastPathComponent,&info,AT_SYMLINK_NOFOLLOW) != 0 {success = errno == ENOENT}
                else if (info.st_mode & S_IFMT)==S_IFREG && info.st_uid==getuid() && info.st_nlink==1 {success = unlinkat(dir,file.lastPathComponent,0)==0}
                close(dir)
            } else {success = errno == ENOENT}
            DispatchQueue.main.async {completion(success)}
        }
    }
    func disableAndDrain() {
        lock.lock(); pending.removeAll(); lock.unlock()
        queue.sync { }
    }
    func flushForTesting() { queue.sync { drain() } }
}

// Shared by production setup and local fake-stream fixture; no content recorded.
@MainActor final class CaptionConnectionDiagnostic {
    let operation = UUID(), epoch = UUID(), started = ProcessInfo.processInfo.systemUptime
    let session: UUID?
    private var finished = false
    init(session: UUID?) {
        self.session = session
        LocalDiagnostics.shared.record(.captions, .start, .started, operationID: operation, stage: .captionConnectionAndSetup, protocolVersion: .managedSpeechV1, captionSession: session, captionEpoch: epoch)
    }
    func finish(_ outcome: DiagnosticOutcome) {
        guard !finished else { return }; finished = true
        LocalDiagnostics.shared.record(.captions, .complete, outcome, duration: ProcessInfo.processInfo.systemUptime - started, operationID: operation, stage: .captionConnectionAndSetup, protocolVersion: .managedSpeechV1, captionSession: session, captionEpoch: epoch)
    }
}
