import Foundation
import EventKit
import Contacts
import Cocoa
import Photos
import Vision
import Speech

// MARK: - Logger
struct Logger {
    static var verbose = false
    static func debug(_ msg: String) { if verbose { fputs("🔍 [DEBUG] \(msg)\n", stderr) } }
    static func error(_ msg: String, exitCode: Int32 = 1) {
        fputs("❌ [ERROR] \(msg)\n", stderr)
        exit(exitCode)
    }
    static func info(_ msg: String) { print(msg) }
}

// MARK: - Config
struct Config: Codable {
    var notes_root: String
    var python_path: String
    var transcribe_script: String
    var ollama_url: String
    var ollama_model: String
    var screenshot_interval: Double
    
    static func defaultConfig() -> Config {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return Config(
            notes_root: "\(home)/Notebooks/journal",
            python_path: "\(home)/Work/iKit/tmp/funasr_env/bin/python3",
            transcribe_script: "\(home)/Work/iKit/scripts/transcribe.py",
            ollama_url: "http://localhost:11434/api/generate",
            ollama_model: "qwen3:4b",
            screenshot_interval: 10.0
        )
    }
}

class ConfigManager {
    static let shared = ConfigManager()
    var current: Config
    private init() {
        self.current = Config.defaultConfig()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".config/ikit/config.json")
        if let data = try? Data(contentsOf: path),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            self.current = decoded
        }
    }
    func save() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/ikit")
        let path = dir.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self.current) {
            try? data.write(to: path)
            Logger.info("💾 Config saved to \(path.path)")
        }
    }
}

// MARK: - Notes Bridge
class NotesBridge: NSObject {
    static let shared = NotesBridge()
    private override init() { super.init() }

    private func executeAppleScript(_ script: String) -> String? {
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary? = nil
        let output = appleScript?.executeAndReturnError(&error)
        if let err = error {
            Logger.debug("AppleScript Error: \(err)")
            return nil
        }
        return output?.stringValue
    }

    private func escape(_ string: String) -> String {
        let bs = String(Character(UnicodeScalar(92)!))
        let qt = String(Character(UnicodeScalar(34)!))
        return string.replacingOccurrences(of: bs, with: bs+bs).replacingOccurrences(of: qt, with: bs+qt)
    }

    func listRecentlyModified(since date: Date) -> [(id: String, name: String, folderId: String, modDate: Date?)] {
        let c = Calendar.current
        let script = """
        tell application "Notes"
            set targetDate to current date
            set year of targetDate to \(c.component(.year, from: date))
            set month of targetDate to \(c.component(.month, from: date))
            set day of targetDate to \(c.component(.day, from: date))
            set hours of targetDate to \(c.component(.hour, from: date))
            set minutes of targetDate to \(c.component(.minute, from: date))
            set seconds of targetDate to \(c.component(.second, from: date))
            if (count of accounts) = 0 then return ""
            set targetAccount to first account
            try
                set recentNotes to every note of targetAccount whose modification date > targetDate
                set resultList to {}
                repeat with n in recentNotes
                    set nid to id of n
                    set nname to name of n
                    set d to modification date of n
                    set dStr to (year of d as string) & "-" & (month of d as integer as string) & "-" & (day of d as string) & " " & (hours of d as string) & ":" & (minutes of d as string) & ":" & (seconds of d as string)
                    set fid to id of container of n
                    set end of resultList to nid & "|||" & nname & "|||" & fid & "|||" & dStr
                end repeat
                set AppleScript's text item delimiters to "###"
                return resultList as string
            on error
                return ""
            end try
        end tell
        """
        guard let out = executeAppleScript(script) else { return [] }
        let f = DateFormatter(); f.dateFormat = "yyyy-M-d H:m:s"
        return out.components(separatedBy: "###").filter{!$0.isEmpty}.compactMap {
            let p = $0.components(separatedBy: "|||")
            return p.count >= 4 ? (p[0], p[1], p[2], f.date(from: p[3])) : nil
        }
    }
    
    func listFoldersWithIds() -> [(id: String, path: String)] {
        let script = """
        tell application "Notes"
            set allFolders to every folder
            set resultList to {}
            repeat with aFolder in allFolders
                set currentFolder to aFolder
                set folderPath to name of currentFolder
                set folderId to id of aFolder
                repeat while container of currentFolder is not missing value
                    set parentContainer to container of currentFolder
                    if class of parentContainer is folder then
                        set folderPath to (name of parentContainer) & "/" & folderPath
                        set currentFolder to parentContainer
                    else
                        exit repeat
                    end if
                end repeat
                set end of resultList to folderId & "|||" & folderPath
            end repeat
            set AppleScript's text item delimiters to "###"
            return resultList as string
        end tell
        """
        guard let output = executeAppleScript(script) else { return [] }
        return output.components(separatedBy: "###").filter{!$0.isEmpty}.compactMap {
            let p = $0.components(separatedBy: "|||")
            return p.count >= 2 ? (p[0], p[1]) : nil
        }
    }

    func readNote(id: String) -> String? {
        executeAppleScript("tell application \"Notes\" to get plaintext of note id \"\(id)\"" )
    }
    func createNote(name: String, folderId: String, content: String) -> Bool {
        let escName = escape(name); let escContent = escape(content)
        return executeAppleScript("tell application \"Notes\" to make new note at folder id \"\(folderId)\" with properties {name:\"\(escName)\", body:\"\(escContent)\"}") != nil
    }
    func appendToNote(name: String, folderId: String, content: String) -> Bool {
        let escName = escape(name)
        let bs = String(Character(UnicodeScalar(92)!))
        let escContent = escape(content).replacingOccurrences(of: bs + "n", with: "<br>")
        let script = "tell application \"Notes\"\nset theNote to first note in folder id \"\(folderId)\" whose name is \"\(escName)\"\nset body of theNote to (body of theNote) & \"<br>\" & \"\(escContent)\"\nend tell"
        return executeAppleScript(script) != nil
    }
    func updateNote(name: String, folderId: String, content: String) -> Bool {
        let escName = escape(name); let escContent = escape(content).replacingOccurrences(of: "\\n", with: "<br>")
        return executeAppleScript("tell application \"Notes\" to set body of (first note in folder id \"\(folderId)\" whose name is \"\(escName)\") to \"\(escContent)\"") != nil
    }
    func deleteNote(name: String, folderId: String) -> Bool {
        let escName = escape(name)
        return executeAppleScript("tell application \"Notes\" to delete (first note in folder id \"\(folderId)\" whose name is \"\(escName)\")") != nil
    }
}

// MARK: - Notes Tool
class NotesTool {
    let bridge = NotesBridge.shared
    let fm = FileManager.default
    
    func sync(targetDir: String) {
        Logger.info("🧠 Smart Sync to: \(targetDir)")
        try? fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        let timeFile = (targetDir as NSString).appendingPathComponent(".last_sync_time")
        var lastSync = Date(timeIntervalSince1970: 0)
        if let ts = try? String(contentsOfFile: timeFile, encoding: .utf8), let t = TimeInterval(ts.trimmingCharacters(in: .whitespacesAndNewlines)) {
            lastSync = Date(timeIntervalSince1970: t)
        }
        let checkDate = lastSync == Date(timeIntervalSince1970: 0) ? lastSync : lastSync.addingTimeInterval(-60)
        
        let folderMap = Dictionary(uniqueKeysWithValues: bridge.listFoldersWithIds())
        let notes = bridge.listRecentlyModified(since: checkDate)
        
        if !notes.isEmpty {
            Logger.debug("⚡️ Found \(notes.count) changes.")
            for note in notes {
                let folderPathString = folderMap[note.folderId] ?? "Unknown"
                let folderPath = (targetDir as NSString).appendingPathComponent(folderPathString)
                try? fm.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
                let safeName = note.name.replacingOccurrences(of: "/", with: ":")
                let filePath = (folderPath as NSString).appendingPathComponent("\(safeName).md")
                Logger.info("  ⬇️ \(note.name)")
                if fm.fileExists(atPath: filePath) { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: filePath) }
                if let content = bridge.readNote(id: note.id) {
                    try? content.write(toFile: filePath, atomically: true, encoding: .utf8)
                    try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: filePath)
                }
            }
        } else { Logger.info("✅ Up to date.") }
        try? String(Date().timeIntervalSince1970).write(toFile: timeFile, atomically: true, encoding: .utf8)
    }
}

// MARK: - Reminders Tool
class RemindersTool {
    let store = EKEventStore()
    func checkPermission() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .authorized { return true }
        if #available(macOS 14.0, *) {
            return (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            return (try? await store.requestAccess(to: .reminder)) ?? false
        }
    }
    func listTasks(json: Bool = false) async {
        guard await checkPermission() else { return }
        let predicate = store.predicateForReminders(in: nil)
        let items = await withCheckedContinuation { c in store.fetchReminders(matching: predicate) { r in c.resume(returning: r) } }
        guard let reminders = items else { return }
        let incomplete = reminders.filter { !$0.isCompleted }
        if json {
            let dicts = incomplete.map { ["id" : $0.calendarItemIdentifier, "title" : $0.title ?? "", "list" : $0.calendar.title] }
            if let data = try? JSONSerialization.data(withJSONObject: dicts, options: []) { print(String(data: data, encoding: .utf8)!) }
        } else {
            for t in incomplete { Logger.info("[\(t.calendar.title)] \(t.title ?? "")") }
        }
    }
    func newTask(title: String) async {
        guard await checkPermission() else { return }
        let item = EKReminder(eventStore: store)
        item.title = title; item.calendar = store.defaultCalendarForNewReminders()
        try? store.save(item, commit: true); Logger.info("✅ Created: \(title)")
    }
}

// MARK: - Calendar Tool
class CalendarTool {
    let store = EKEventStore()
    func checkPermission() async -> Bool {
        if #available(macOS 14.0, *) {
            if EKEventStore.authorizationStatus(for: .event) == .authorized { return true }
            return (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            if EKEventStore.authorizationStatus(for: .event) == .authorized { return true }
            return (try? await store.requestAccess(to: .event)) ?? false
        }
    }
    func listEvents(json: Bool = false) async {
        guard await checkPermission() else { return }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        if json {
            let dicts = events.map { ["id": $0.eventIdentifier ?? "", "title": $0.title ?? "", "start": "\($0.startDate)", "calendar": $0.calendar.title] }
            if let data = try? JSONSerialization.data(withJSONObject: dicts, options: []) { print(String(data: data, encoding: .utf8)!) }
        } else {
            for e in events { Logger.info("[\(e.calendar.title)] \(e.startDate) \(e.title ?? "")") }
        }
    }
}

// MARK: - Contacts Tool
class ContactsTool {
    let store = CNContactStore()
    func checkPermission() async -> Bool {
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized { return true }
        return (try? await store.requestAccess(for: .contacts)) ?? false
    }
    func search(query: String, json: Bool = false) async {
        guard await checkPermission() else { return }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let req = CNContactFetchRequest(keysToFetch: keys); req.predicate = CNContact.predicateForContacts(matchingName: query)
        var results: [[String: Any]] = []
        try? store.enumerateContacts(with: req) { c, _ in
            results.append(["name": "\(c.givenName) \(c.familyName)", "phones": c.phoneNumbers.map { $0.value.stringValue }])
        }
        if json {
            if let data = try? JSONSerialization.data(withJSONObject: results, options: []) { print(String(data: data, encoding: .utf8)!) }
        } else {
            for c in results { Logger.info("👤 \(c["name"] ?? "")") }
        }
    }
}

// MARK: - Photo Tool
class PhotoTool {
    func checkPermission() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized || status == .limited { return true }
        return await withCheckedContinuation { c in 
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in c.resume(returning: s == .authorized || s == .limited) } 
        }
    }
    func listRecent(count: Int, screenshots: Bool, favorites: Bool, json: Bool) async {
        guard await checkPermission() else { return }
        let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]; options.fetchLimit = count
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        assets.enumerateObjects { asset, _, _ in Logger.info("🖼 ID: \(asset.localIdentifier)") }
    }
    func ocr(assetId: String) async {
        guard await checkPermission() else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = assets.firstObject else { return }
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: nil) { data, _, _, _ in
            guard let data = data, let cgImage = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let request = VNRecognizeTextRequest { req, _ in
                let strings = (req.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string }
                print(strings?.joined(separator: "\n") ?? "")
            }
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }
    }
}

// MARK: - Shortcuts Tool
class ShortcutsTool {
    func listShortcuts() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["list"]
        let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
        if let data = try? pipe.fileHandleForReading.readDataToEndOfFile(), let output = String(data: data, encoding: .utf8) { print(output) }
    }
    func runShortcut(name: String, input: String? = nil) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        var args = ["run", name]; if let i = input { args.append(contentsOf: ["--input-text", i]) }
        p.arguments = args; try? p.run(); p.waitUntilExit()
    }
}

// MARK: - Shell Helper
class Shell {
    static func run(_ command: String, args: [String]) -> (output: String?, error: String?, exitCode: Int32) {
        let task = Process(); task.executableURL = URL(fileURLWithPath: command); task.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe(); task.standardOutput = outPipe; task.standardError = errPipe
        do {
            try task.run(); task.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile(); let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            return (String(data: outData, encoding: .utf8), String(data: errData, encoding: .utf8), task.terminationStatus)
        } catch { return (nil, "Failed: \(error)", -1) }
    }
}

// MARK: - FunASR Models
struct FunASRSentence: Codable {
    let text: String; let spk: Int?; let start: Int?; let end: Int?
}
struct FunASRItem: Codable {
    let key: String?; let text: String?; let sentence_info: [FunASRSentence]?
}

// MARK: - Secretary Tool
class SecretaryTool {
    let logger = Logger.self
    let config = ConfigManager.shared.current
    
    private func summarize(text: String, visualContext: String = "") async -> String {
        let url = URL(string: config.ollama_url)!
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 300)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let prompt = "你是一个专业的会议秘书。结合转录和截图生成一份精准的结构化纪要，尽可能使用真实姓名：\n\(text.prefix(12000))\n视觉上下文：\n\(visualContext)"
        let body: [String: Any] = ["model": config.ollama_model, "prompt": prompt, "stream": false]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let res = json["response"] as? String { return res }
        } catch { Logger.debug("Ollama Error: \(error)") }
        return "⚠️ Summarization failed."
    }
    
    private func performOCR(on imagePath: String) async -> String {
        let url = URL(fileURLWithPath: imagePath)
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return "" }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let strings = (req.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: strings?.joined(separator: " ") ?? "")
            }
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        }
    }

    private func formatDialogue(from items: [FunASRItem]) -> String {
        var out = ""
        for item in items {
            item.sentence_info?.forEach { out += "[Speaker \($0.spk ?? 0)]: \($0.text)\n" }
        }
        return out
    }

    func process(files: [String], outputDir: String) async {
        let fm = FileManager.default
        for file in files {
            guard fm.fileExists(atPath: file) else { continue }
            logger.info("🤖 Processing: \(file)")
            var content = ""
            if file.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: file)), let items = try? JSONDecoder().decode([FunASRItem].self, from: data) {
                content = formatDialogue(from: items)
            } else { content = (try? String(contentsOfFile: file, encoding: .utf8)) ?? "" }
            
            if content.isEmpty { continue }
            
            let fileDir = (file as NSString).deletingLastPathComponent
            let screenshots = (try? fm.contentsOfDirectory(atPath: fileDir))?.filter { $0.contains("screenshot_") && $0.hasSuffix(".jpg") }.sorted() ?? []
            var visualContext = ""
            for shot in screenshots.prefix(10) {
                let text = await performOCR(on: "\(fileDir)/\(shot)")
                visualContext += "Screenshot \(shot): \(text)\n"
            }
            
            let summary = await summarize(text: content, visualContext: visualContext)
            let outPath = (outputDir as NSString).appendingPathComponent("\(ISO8601DateFormatter().string(from: Date()))-" + (file as NSString).lastPathComponent + ".md")
            try? summary.write(toFile: outPath, atomically: true, encoding: .utf8)
            Logger.info("✅ Saved to: \(outPath)")
        }
    }

    func transcribe(audioPath: String) async {
        let out = URL(fileURLWithPath: audioPath).deletingPathExtension().appendingPathExtension("json").path
        Logger.info("🎤 Transcribing (FunASR): \(audioPath)")
        _ = Shell.run(config.python_path, args: [config.transcribe_script, audioPath, "--output", out])
    }
}

// MARK: - App Main
@main
struct App {
    static let VERSION = "2.3.2"
    static func main() async {
        let args = CommandLine.arguments; let configManager = ConfigManager.shared
        if args.contains("-v") || args.contains("--verbose") { Logger.verbose = true }
        if args.contains("--version") { print("iKit version \(VERSION)"); return }
        guard args.count > 1 else { printHelp(); return }
        let cmd = args[1]; let sub = args.count > 2 ? args[2] : ""
        
        switch cmd {
        case "config":
            if sub == "init" { configManager.save() }
            else if sub == "show" { if let data = try? JSONEncoder().encode(configManager.current), let str = String(data: data, encoding: .utf8) { print(str) } } else { print("Usage: ikit config [init|show]") }
        case "task":
            let t = RemindersTool()
            if sub == "list" { await t.listTasks(json: args.contains("--json")) }
            else if sub == "new" && args.count > 3 { await t.newTask(title: args[3]) }
            else { print("Usage: ikit task list|new") }
        case "cal":
            let t = CalendarTool()
            if sub == "list" { await t.listEvents(json: args.contains("--json")) }
            else { print("Usage: ikit cal list") }
        case "contact":
            if sub == "search" && args.count > 3 { await ContactsTool().search(query: args[3], json: args.contains("--json")) }
            else { print("Usage: ikit contact search <name>") }
        case "photo":
            let t = PhotoTool()
            if sub == "list" { await t.listRecent(count: 10, screenshots: true, favorites: false, json: args.contains("--json")) }
            else if sub == "ocr" && args.count > 3 { await t.ocr(assetId: args[3]) }
            else { print("Usage: ikit photo list|ocr") }
        case "sc":
            let t = ShortcutsTool()
            if sub == "list" { t.listShortcuts() }
            else if sub == "run" && args.count > 3 { t.runShortcut(name: args[3], input: args.count > 4 ? args[4] : nil) }
            else { print("Usage: ikit sc list|run") }
        case "note":
            let root = args.count > 3 && !args[3].starts(with: "-") ? args[3] : configManager.current.notes_root
            if sub == "sync" { NotesTool().sync(targetDir: root) }
            else { print("Usage: ikit note sync [path]") }
        case "meet":
            let t = SecretaryTool()
            if sub == "process" && args.count > 3 {
                let outDir = args.last!.starts(with: "/") ? args.last! : configManager.current.notes_root
                let files = Array(args[3..<args.count-1]); await t.process(files: files, outputDir: outDir)
            } else if sub == "transcribe" && args.count > 3 { await t.transcribe(audioPath: args[3]) }
            else if sub == "record" && args.count > 3 {
                if #available(macOS 13.0, *) {
                    let rec = MeetingRecorder(); let out = args[3]
                    var dur: Double? = nil
                    if let idx = args.firstIndex(of: "--duration"), idx + 1 < args.count { dur = Double(args[idx+1]) }
                    let apps = args.filter { !$0.starts(with: "-") && $0 != out && $0 != cmd && $0 != sub }
                    try? await rec.start(targetAppKeywords: apps.isEmpty ? ["Teams", "Meeting"] : apps, outputPath: out, duration: dur, screenshotInterval: configManager.current.screenshot_interval)
                    if dur == nil { _ = readLine(); try? await rec.stop() }
                    else { while !rec.isFinished { try? await Task.sleep(nanoseconds: 500_000_000) } }
                }
            } else { print("Usage: ikit meet [process|transcribe|record]") }
        default: printHelp()
        }
    }
    static func printHelp() {
        print("iKit v\(VERSION) | meet [process|transcribe|record] | note sync | task list | cal list | contact search | photo list | sc list")
    }
}
