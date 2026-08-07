import Foundation

/// Minimal append-only diagnostic log at ~/Library/Logs/HeadsUp/headsup.log.
/// Used for the handful of events that are hard to observe any other way
/// (alert focus state, escape handling). Never logs secrets or event content.
/// One handle is opened with O_APPEND (every write appends atomically, no
/// seek to go wrong) and the file rotates to headsup.old.log past 512 KB.
enum FileDiag {
    private static let queue = DispatchQueue(label: "headsup.filediag")
    private static let maxBytes: UInt64 = 512 * 1024
    private static var handle: FileHandle?

    private static let logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/HeadsUp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("headsup.log")
    }()

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Queue-confined. Rotates once per process at open time, then keeps the
    /// appending handle for the process lifetime.
    private static func openHandle() -> FileHandle? {
        if let handle { return handle }
        let path = logURL.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        if let size = (attrs?[.size] as? NSNumber)?.uint64Value, size > maxBytes {
            let old = logURL.deletingLastPathComponent().appendingPathComponent("headsup.old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: logURL, to: old)
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle = h
        return h
    }

    static func log(_ message: String) {
        queue.async {
            let line = "\(timestamp.string(from: Date())) \(message)\n"
            try? openHandle()?.write(contentsOf: Data(line.utf8))
        }
    }
}
