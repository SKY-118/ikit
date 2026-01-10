import Foundation
import EventKit
import Contacts
import Cocoa
import Photos
import Vision

let VERSION = "2.3.0"

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
    var notes_root: String?
}

class ConfigManager {
    static let shared = ConfigManager()
    func load() -> Config? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".config/ikit/config.json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
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

    func listRecentlyModified(since date: Date) -> [(id: String, name: String, path: String, modDate: Date?)] {
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
                    set currentFolder to container of n
                    set folderPath to name of currentFolder
                    repeat while container of currentFolder is not missing value
                        set parentContainer to container of currentFolder
                        if class of parentContainer is folder then
                            set folderPath to (name of parentContainer) & "/" & folderPath
                            set currentFolder to parentContainer
                        else
                            exit repeat
                        end if
                    end repeat
                    set end of resultList to nid & "|||" & nname & "|||" & folderPath & "|||" & dStr
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
        return out.components(separatedBy: "###").filter{!$0.isEmpty}.compactMap { item in
            let p = item.components(separatedBy: "|||")
            return p.count >= 4 ? (p[0], p[1], p[2], f.date(from: p[3])) : nil
        }
    }
    
    func listFoldersWithIds() -> [(id: String, path: String, name: String)] {
        let script = """
        tell application "Notes"
            set allFolders to every folder
            set resultList to {}
            repeat with aFolder in allFolders
                set currentFolder to aFolder
                set folderPath to name of currentFolder
                set folderName to name of currentFolder
                repeat while container of currentFolder is not missing value
                    set parentContainer to container of currentFolder
                    if class of parentContainer is folder then
                        set folderPath to (name of parentContainer) & "/" & folderPath
                        set currentFolder to parentContainer
                    else
                        exit repeat
                    end if
                end repeat
                set end of resultList to (id of aFolder) & "|||" & folderPath & "|||" & folderName
            end repeat
            set AppleScript's text item delimiters to "###"
            return resultList as string
        end tell
        """
        guard let output = executeAppleScript(script) else { return [] }
        return output.components(separatedBy: "###").filter{!$0.isEmpty}.compactMap {
            let p = $0.components(separatedBy: "|||")
            return p.count >= 3 ? (p[0], p[1], p[2]) : nil
        }
    }
    
    func listNotesMetadata(inFolderId folderId: String) -> [(name: String, modDate: Date?)] {
        let script = """
        tell application "Notes"
            try
                set targetFolder to folder id "\(folderId)"
                set noteList to every note in targetFolder
                set resultList to {}
                repeat with n in noteList
                    set d to modification date of n
                    set dStr to (year of d as string) & "-" & (month of d as integer as string) & "-" & (day of d as string) & " " & (hours of d as string) & ":" & (minutes of d as string) & ":" & (seconds of d as string)
                    set end of resultList to (name of n) & "|||" & dStr
                end repeat
                set AppleScript's text item delimiters to "###"
                return resultList as string
            on error
                return ""
            end try
        end tell
        """
        guard let output = executeAppleScript(script) else { return [] }
        let f = DateFormatter(); f.dateFormat = "yyyy-M-d H:m:s"
        return output.components(separatedBy: "###").filter{!$0.isEmpty}.compactMap {
            let p = $0.components(separatedBy: "|||")
            return p.count >= 2 ? (p[0], f.date(from: p[1])) : nil
        }
    }

    func readNote(id: String) -> String? {
        executeAppleScript("tell application \"Notes\" to get plaintext of note id \"\(id)\"")
    }
    func createNote(name: String, folderId: String, content: String) -> Bool {
        let escName = escape(name); let escContent = escape(content)
        return executeAppleScript("tell application \"Notes\" to make new note at folder id \"\(folderId)\" with properties {name:\"\(escName)\", body:\"\(escContent)\"}") != nil
    }
    func appendToNote(name: String, folderId: String, content: String) -> Bool {
        let escName = escape(name)
        let bs = String(Character(UnicodeScalar(92)!))
        let escContent = escape(content).replacingOccurrences(of: bs + "n", with: "<br>")
        let script = """
        tell application "Notes"
            set theNote to first note in folder id "\(folderId)" whose name is "\(escName)"
            set body of theNote to (body of theNote) & "<br>" & "\(escContent)"
        end tell
        """
        return executeAppleScript(script) != nil
    }
    func updateNote(name: String, folderId: String, content: String) -> Bool {
        let escName = escape(name)
        let bs = String(Character(UnicodeScalar(92)!))
        let escContent = escape(content).replacingOccurrences(of: bs + "n", with: "<br>")
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
        Logger.debug("🧠 Smart Sync to: \(targetDir)")
        try? fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        let timeFile = (targetDir as NSString).appendingPathComponent(".last_sync_time")
        var lastSync = Date(timeIntervalSince1970: 0)
        if let ts = try? String(contentsOfFile: timeFile, encoding: .utf8), let t = TimeInterval(ts.trimmingCharacters(in: .whitespacesAndNewlines)) {
            lastSync = Date(timeIntervalSince1970: t)
        }
        let checkDate = lastSync == Date(timeIntervalSince1970: 0) ? lastSync : lastSync.addingTimeInterval(-60)
        let notes = bridge.listRecentlyModified(since: checkDate)
        if !notes.isEmpty {
            Logger.debug("⚡️ Found \(notes.count) changes.")
            for note in notes {
                let folderPath = (targetDir as NSString).appendingPathComponent(note.path)
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
        } else { Logger.debug("✅ Up to date.") }
        try? String(Date().timeIntervalSince1970).write(toFile: timeFile, atomically: true, encoding: .utf8)
    }
    
    func findFolderId(path: String) -> String? {
        let folders = bridge.listFoldersWithIds()
        return folders.first(where: { $0.path == path })?.id ?? folders.first(where: { $0.name == path })?.id
    }
    
    func create(targetDir: String, folder: String, title: String, content: String) {
        guard let fid = findFolderId(path: folder) else { Logger.error("Folder not found"); return }
        if bridge.createNote(name: title, folderId: fid, content: content) { Logger.info("✅ Created."); sync(targetDir: targetDir) } else { Logger.error("Failed.") }
    }
    func append(targetDir: String, folder: String, title: String, content: String) {
        guard let fid = findFolderId(path: folder) else { Logger.error("Folder not found"); return }
        if bridge.appendToNote(name: title, folderId: fid, content: content) { Logger.info("✅ Appended."); sync(targetDir: targetDir) } else { Logger.error("Failed.") }
    }
    func update(targetDir: String, folder: String, title: String, content: String) {
        guard let fid = findFolderId(path: folder) else { Logger.error("Folder not found"); return }
        if bridge.updateNote(name: title, folderId: fid, content: content) { Logger.info("✅ Updated."); sync(targetDir: targetDir) } else { Logger.error("Failed.") }
    }
    func delete(targetDir: String, folder: String, title: String) {
        guard let fid = findFolderId(path: folder) else { Logger.error("Folder not found"); return }
        if bridge.deleteNote(name: title, folderId: fid) {
            Logger.info("✅ Deleted.")
            let safeName = title.replacingOccurrences(of: "/", with: ":")
            let localPath = (targetDir as NSString).appendingPathComponent(folder).appending("/\(safeName).md")
            if fm.fileExists(atPath: localPath) {
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: localPath)
                try? fm.removeItem(atPath: localPath)
            }
        } else { Logger.error("Failed.") }
    }
}

// MARK: - Reminders Tool
class RemindersTool {
    let store = EKEventStore()
    func checkPermission() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .authorized { return true }
        if status == .notDetermined { return (try? await store.requestAccess(to: .reminder)) ?? false }
        return false
    }
    func listTasks(json: Bool = false) async {
        guard await checkPermission() else { return }
        let predicate = store.predicateForReminders(in: nil)
        let items = await withCheckedContinuation { c in store.fetchReminders(matching: predicate) { r in c.resume(returning: r) } }
        guard let reminders = items else { return }
        let incomplete = reminders.filter { !$0.isCompleted }
        if json {
            let f = ISO8601DateFormatter()
            let dicts = incomplete.map { r -> [String: Any] in
                var d: String? = nil
                if let date = r.dueDateComponents?.date { d = f.string(from: date) }
                return ["id" : r.calendarItemIdentifier, "title" : r.title ?? "", "list" : r.calendar.title, "isCompleted" : r.isCompleted, "priority" : r.priority, "dueDate" : d ?? NSNull()]
            }
            if let data = try? JSONSerialization.data(withJSONObject: dicts, options: .prettyPrinted) { print(String(data: data, encoding: .utf8)!) }
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
    func completeTask(query: String, isId: Bool) async {
        guard await checkPermission() else { return }
        let items = await withCheckedContinuation { c in store.fetchReminders(matching: store.predicateForReminders(in: nil)) { r in c.resume(returning: r) } }
        let t = items?.first(where: { isId ? $0.calendarItemIdentifier == query : ($0.title == query && !$0.isCompleted) })
        if let t = t { t.isCompleted = true; try? store.save(t, commit: true); Logger.info("✅ Completed") }
    }
    func deleteTask(query: String, isId: Bool, dryRun: Bool) async {
        guard await checkPermission() else { return }
        let items = await withCheckedContinuation { c in store.fetchReminders(matching: store.predicateForReminders(in: nil)) { r in c.resume(returning: r) } }
        let t = items?.first(where: { isId ? $0.calendarItemIdentifier == query : $0.title == query })
        if let t = t { if dryRun { Logger.info("⚠️ Dry-Run: \(t.title ?? "")") } else { try? store.remove(t, commit: true); Logger.info("✅ Deleted") } }
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
            let f = ISO8601DateFormatter()
            let dicts = events.map { e -> [String: Any] in
                return ["id": e.eventIdentifier ?? "", "title": e.title ?? "", "start": f.string(from: e.startDate), "calendar": e.calendar.title]
            }
            if let data = try? JSONSerialization.data(withJSONObject: dicts, options: .prettyPrinted) { print(String(data: data, encoding: .utf8)!) }
        } else {
            let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
            for e in events { Logger.info("[\(e.calendar.title)] \(e.startDate) \(e.title ?? "")") }
        }
    }
    func newEvent(title: String, time: String) async {
        guard await checkPermission() else { return }
        let event = EKEvent(eventStore: store)
        event.title = title; event.calendar = store.defaultCalendarForNewEvents
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        if let d = f.date(from: time) {
            event.startDate = d; event.endDate = d.addingTimeInterval(3600)
            try? store.save(event, span: .thisEvent); Logger.info("✅ Created")
        } else { Logger.error("Invalid Time") }
    }
    func deleteEvent(title: String) async {
        guard await checkPermission() else { return }
        let start = Date(); let end = Calendar.current.date(byAdding: .day, value: 30, to: start)!
        if let e = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)).first(where: { $0.title == title }) {
            try? store.remove(e, span: .thisEvent); Logger.info("✅ Deleted")
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
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactOrganizationNameKey] as [CNKeyDescriptor]
        let req = CNContactFetchRequest(keysToFetch: keys); req.predicate = CNContact.predicateForContacts(matchingName: query)
        var results: [[String: Any]] = []
        try? store.enumerateContacts(with: req) { c, _ in
            results.append(["id": c.identifier, "name": "\(c.givenName) \(c.familyName)", "phones": c.phoneNumbers.map { $0.value.stringValue }, "emails": c.emailAddresses.map { $0.value as String }])
        }
        if json {
            if let data = try? JSONSerialization.data(withJSONObject: results, options: .prettyPrinted) { print(String(data: data, encoding: .utf8)!) }
        } else {
            for c in results { Logger.info("👤 \(c["name"] ?? "")") }
        }
    }
}

// MARK: - Photo Tool
struct PhotoAsset {
    let id: String
    let creationDate: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool
}

class PhotoTool {
    func checkPermission() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized || status == .limited { return true }
        return await withCheckedContinuation { c in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in c.resume(returning: s == .authorized || s == .limited) }
        }
    }
    
    private func fetchAssets(count: Int, screenshots: Bool, favorites: Bool) async -> [PhotoAsset] {
        guard await checkPermission() else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = count
        var predicates: [NSPredicate] = []
        if screenshots { predicates.append(NSPredicate(format: "(mediaSubtype & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)) }
        if favorites { predicates.append(NSPredicate(format: "isFavorite == YES")) }
        if !predicates.isEmpty { options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var results: [PhotoAsset] = []
        assets.enumerateObjects { asset, _, _ in
            results.append(PhotoAsset(id: asset.localIdentifier, creationDate: asset.creationDate ?? Date(), pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, isFavorite: asset.isFavorite))
        }
        return results
    }
    
    func listRecent(count: Int = 10, screenshots: Bool = false, favorites: Bool = false, json: Bool = false) async {
        let assets = await fetchAssets(count: count, screenshots: screenshots, favorites: favorites)
        if json {
            let dicts = assets.map { ["id": $0.id, "date": ISO8601DateFormatter().string(from: $0.creationDate), "width": $0.pixelWidth, "height": $0.pixelHeight, "isFavorite": $0.isFavorite] }
            if let data = try? JSONSerialization.data(withJSONObject: dicts, options: .prettyPrinted) { print(String(data: data, encoding: .utf8)!) }
        } else {
            for r in assets { Logger.info("🖼 ID: \(r.id)") }
        }
    }
    
    func batchOcr(count: Int, screenshots: Bool, favorites: Bool) async {
        let assets = await fetchAssets(count: count, screenshots: screenshots, favorites: favorites)
        if assets.isEmpty { Logger.info("No photos found."); return }
        Logger.info("🔄 Batch OCR for \(assets.count) images...")
        for asset in assets {
            Logger.info("\n📸 Photo: \(asset.id)")
            await ocr(assetId: asset.id)
        }
    }
    
    func ocr(assetId: String) async {
        guard await checkPermission() else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = assets.firstObject else { Logger.error("Photo not found"); return }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            guard let data = data, let source = CGImageSourceCreateWithData(data as CFData, nil), let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            let request = VNRecognizeTextRequest { req, _ in
                guard let obs = req.results as? [VNRecognizedTextObservation] else { return }
                print(obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
            }
            request.recognitionLanguages = ["zh-Hans", "en-US"]; request.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }
    }
}

// MARK: - Shortcuts Tool
class ShortcutsTool {
    func listShortcuts() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["list"]
        let pipe = Pipe(); p.standardOutput = pipe; try? p.run()
        if let data = try? pipe.fileHandleForReading.readDataToEndOfFile(), let output = String(data: data, encoding: .utf8) { print(output) }
    }
    func runShortcut(name: String, input: String? = nil) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        var args = ["run", name]; if let i = input { args.append(contentsOf: ["--input-text", i]) }
        p.arguments = args; try? p.run(); p.waitUntilExit()
    }
}

// MARK: - Main
@main
struct App {
    static func main() async {
        let args = CommandLine.arguments; let config = ConfigManager.shared.load()
        let json = args.contains("--json"); let dryRun = args.contains("--dry-run"); let isId = args.contains("--id")
        let isHelp = args.contains("--help") || args.contains("-h")
        let isScreenshots = args.contains("--screenshots"); let isFavorites = args.contains("--favorites")
        if args.contains("-v") || args.contains("--verbose") { Logger.verbose = true }
        if args.contains("--version") { Logger.info("iKit version \(VERSION)"); return }
        if isHelp { printHelp(for: args.count > 1 ? args[1] : nil); return }
        guard args.count > 1 else { printHelp(for: nil); return }
        let cmd = args[1]; let sub = args.count > 2 ? args[2] : ""
        func getRoot() -> String? {
            if args.count > 3 && !args[3].starts(with: "-") { return args[3] }
            return config?.notes_root?.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
        }
        func getIntParam(_ name: String) -> Int? {
            if let idx = args.firstIndex(of: name), idx + 1 < args.count { return Int(args[idx + 1]) }
            return nil
        }
        let count = getIntParam("--last") ?? 10
        switch cmd {
        case "task":
            let t = RemindersTool()
            if sub == "list" { await t.listTasks(json: json) }
            else if sub == "new" && args.count > 3 { await t.newTask(title: args[3]) }
            else if sub == "complete" && args.count > 3 { await t.completeTask(query: args[3], isId: isId) }
            else if sub == "delete" && args.count > 3 { await t.deleteTask(query: args[3], isId: isId, dryRun: dryRun) }
            else { printHelp(for: "task") }
        case "cal":
            let t = CalendarTool()
            if sub == "list" { await t.listEvents(json: json) }
            else if sub == "new" && args.count > 4 { await t.newEvent(title: args[3], time: args[4]) }
            else if sub == "delete" && args.count > 3 { await t.deleteEvent(title: args[3]) }
            else { printHelp(for: "cal") }
        case "contact":
            if sub == "search" && args.count > 3 { await ContactsTool().search(query: args[3], json: json) }
            else { printHelp(for: "contact") }
        case "photo":
            let t = PhotoTool()
            if sub == "list" { await t.listRecent(count: count, screenshots: isScreenshots, favorites: isFavorites, json: json) }
            else if sub == "ocr" {
                if args.count > 3 && !args[3].starts(with: "-") { await t.ocr(assetId: args[3]) }
                else { await t.batchOcr(count: count, screenshots: isScreenshots, favorites: isFavorites) }
            } else { printHelp(for: "photo") }
        case "sc":
            let t = ShortcutsTool()
            if sub == "list" { t.listShortcuts() }
            else if sub == "run" && args.count > 3 { t.runShortcut(name: args[3], input: args.count > 4 ? args[4] : nil) }
            else { printHelp(for: "sc") }
        case "note":
            let t = NotesTool()
            guard let root = getRoot() else { Logger.error("Missing root"); return }
            if sub == "sync" { t.sync(targetDir: root) }
            else if sub == "new" && args.count > 6 { t.create(targetDir: root, folder: args[4], title: args[5], content: args[6]) }
            else if sub == "append" && args.count > 6 { t.append(targetDir: root, folder: args[4], title: args[5], content: args[6]) }
            else if sub == "update" && args.count > 6 { t.update(targetDir: root, folder: args[4], title: args[5], content: args[6]) }
            else if sub == "delete" && args.count > 5 { t.delete(targetDir: root, folder: args[4], title: args[5]) }
            else { printHelp(for: "note") }
        default: print("iKit v\(VERSION) | Usage: ikit [task|cal|note|photo|contact|sc] --help")
        }
    }
    static func printHelp(for command: String?) {
        let h: String
        switch command {
        case "task": h = "Task: list [--json], new <title>, complete <query> [--id], delete <query> [--id] [--dry-run]"
        case "cal":  h = "Calendar: list [--json], new <title> <YYYY-MM-DD HH:mm>, delete <title>"
        case "note": h = "Note: sync [path], new [path] <folder> <title> <content>, append/update/delete ..."
        case "photo": h = "Photo: list [--json] [--screenshots] [--favorites] [--last N], ocr [<assetId>] [--screenshots --last N]"
        case "contact": h = "Contact: search <name> [--json]"
        case "sc": h = "Shortcuts: list, run <name> [input]"
        default: h = "iKit v\(VERSION) | Usage: ikit [task|cal|note|photo|contact|sc] [command] [args] [--json] [--id] [--dry-run] [--help] [-v]"
        }
        print(h)
    }
}
