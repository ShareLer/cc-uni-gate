import Foundation

public enum AppPaths {
    private static let currentDirectoryName = "UniGate"

    public static func applicationSupportDirectory() -> URL {
        applicationSupportRoot()
            .appendingPathComponent(currentDirectoryName, isDirectory: true)
    }

    public static func logsDirectory() -> URL {
        applicationSupportDirectory().appendingPathComponent("logs", isDirectory: true)
    }

    public static func logFileURL() -> URL {
        logsDirectory().appendingPathComponent("unigate.log", isDirectory: false)
    }

    private static func applicationSupportRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}
