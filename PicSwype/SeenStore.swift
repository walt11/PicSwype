import CryptoKit
import Foundation

/// Reviewed IDs, one JSON string per line. A swipe appends one line instead of
/// rewriting the whole list; removals (undo, unqueue, restart) rewrite the file.
enum SeenStore {
    static var directory = URL.applicationSupportDirectory.appending(path: "ReviewedIDs", directoryHint: .isDirectory)

    static func url(_ progressKey: String) -> URL {
        let name = SHA256.hash(data: Data(progressKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name + ".jsonl")
    }

    static func load(_ progressKey: String, defaults: UserDefaults = .standard) -> Set<String> {
        let legacy = progressKey + ".seen"
        if let ids = defaults.stringArray(forKey: legacy) {
            let set = Set(ids)
            write(set, progressKey, defaults: defaults)
            return set
        }
        guard let text = try? String(contentsOf: url(progressKey), encoding: .utf8) else { return [] }
        var ids = Set<String>()
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n") {
            if let id = try? decoder.decode(String.self, from: Data(line.utf8)) { ids.insert(id) }
        }
        return ids
    }

    static func append(_ id: String, _ progressKey: String) {
        let legacy = progressKey + ".seen"
        if var ids = UserDefaults.standard.stringArray(forKey: legacy) {
            ids.append(id)
            UserDefaults.standard.set(ids, forKey: legacy)
            return
        }
        guard let line = encode(id) else { return }
        let file = url(progressKey)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? line.write(to: file, options: .atomic)
        }
    }

    static func write(_ ids: Set<String>, _ progressKey: String, defaults: UserDefaults = .standard) {
        var data = Data()
        for id in ids { if let line = encode(id) { data.append(line) } }
        let legacy = progressKey + ".seen"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(progressKey), options: .atomic)
            defaults.removeObject(forKey: legacy)
        } catch {
            defaults.set(Array(ids), forKey: legacy)
        }
    }

    static func remove(_ progressKey: String) {
        write([], progressKey)
        if UserDefaults.standard.object(forKey: progressKey + ".seen") == nil {
            try? FileManager.default.removeItem(at: url(progressKey))
        }
    }

    private static func encode(_ id: String) -> Data? {
        guard var line = try? JSONEncoder().encode(id) else { return nil }
        line.append(0x0A)
        return line
    }
}
