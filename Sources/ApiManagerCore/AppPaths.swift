import Foundation

public enum AppPaths {
    public static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("API Manager", isDirectory: true)
    }

    public static func logsDirectory() -> URL {
        applicationSupportDirectory().appendingPathComponent("logs", isDirectory: true)
    }

    public static func logFileURL() -> URL {
        logsDirectory().appendingPathComponent("api-manager.log", isDirectory: false)
    }
}
