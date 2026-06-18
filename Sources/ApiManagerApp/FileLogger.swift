import ApiManagerCore
import Foundation

final class FileLogger: @unchecked Sendable {
    let fileURL: URL
    private let queue = DispatchQueue(label: "api-manager.file-logger")
    private let formatter = ISO8601DateFormatter()

    init(fileURL: URL = AppPaths.logFileURL()) {
        self.fileURL = fileURL
    }

    func log(_ level: ProxyEvent.Level, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(message)\n"
        queue.async { [fileURL] in
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } catch {
                fputs("API Manager log write failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }
}
