import UniGateCore
import Foundation

final class FileLogger: @unchecked Sendable {
    let fileURL: URL
    private let queue = DispatchQueue(label: "unigate.file-logger")
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return formatter
    }()

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
                fputs("UniGate log write failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }
}
