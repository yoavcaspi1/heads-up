import Foundation

/// JSON-file settings store, thread-confined to the main queue (all UI and
/// scheduler access happens there). Observers fire synchronously after each
/// persisted update, the native stand-in for the "settings:changed" broadcast.
final class SettingsStore {
    private let fileURL: URL
    private var cache: AppSettings
    private var observers: [UUID: (AppSettings) -> Void] = [:]

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("settings.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.cache = AppSettings.sanitized(from: decoded)
        } else {
            self.cache = .defaults
        }
    }

    var settings: AppSettings { cache }

    @discardableResult
    func update(_ mutate: (inout AppSettings) -> Void) -> AppSettings {
        var next = cache
        mutate(&next)
        next = AppSettings.sanitized(from: next)
        cache = next
        persist(next)
        for observer in observers.values { observer(next) }
        return next
    }

    @discardableResult
    func addObserver(_ block: @escaping (AppSettings) -> Void) -> UUID {
        let id = UUID()
        observers[id] = block
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func persist(_ settings: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
