import Foundation

public enum AppPaths {
    private static let currentDirectoryName = "UniGate"
    private static let legacyDirectoryName = "API Manager"

    public static func applicationSupportDirectory() -> URL {
        applicationSupportRoot()
            .appendingPathComponent(currentDirectoryName, isDirectory: true)
    }

    public static func legacyApplicationSupportDirectory() -> URL {
        applicationSupportRoot()
            .appendingPathComponent(legacyDirectoryName, isDirectory: true)
    }

    public static func logsDirectory() -> URL {
        applicationSupportDirectory().appendingPathComponent("logs", isDirectory: true)
    }

    public static func logFileURL() -> URL {
        logsDirectory().appendingPathComponent("unigate.log", isDirectory: false)
    }

    public static func migrateLegacyApplicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws {
        try migrateApplicationSupportDirectory(
            from: legacyApplicationSupportDirectory(),
            to: applicationSupportDirectory(),
            fileManager: fileManager
        )
    }

    public static func migrateApplicationSupportDirectory(
        from legacyDirectory: URL,
        to currentDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let legacyExists = fileManager.fileExists(atPath: legacyDirectory.path)
        guard legacyExists else {
            return
        }

        try fileManager.createDirectory(at: currentDirectory, withIntermediateDirectories: true)

        let items = try fileManager.contentsOfDirectory(
            at: legacyDirectory,
            includingPropertiesForKeys: nil
        )
        for item in items {
            try migrateItem(item, into: currentDirectory, fileManager: fileManager)
        }
        try? fileManager.removeItem(at: legacyDirectory)
    }

    private static func applicationSupportRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static func migrateItem(
        _ item: URL,
        into directory: URL,
        fileManager: FileManager
    ) throws {
        let target = directory.appendingPathComponent(migratedName(for: item.lastPathComponent))
        var itemIsDirectory = ObjCBool(false)
        let itemExists = fileManager.fileExists(atPath: item.path, isDirectory: &itemIsDirectory)
        guard itemExists else {
            return
        }

        var targetIsDirectory = ObjCBool(false)
        let targetExists = fileManager.fileExists(atPath: target.path, isDirectory: &targetIsDirectory)
        if itemIsDirectory.boolValue {
            if !targetExists {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            }
            guard !targetExists || targetIsDirectory.boolValue else {
                return
            }
            let children = try fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
            for child in children {
                try migrateItem(child, into: target, fileManager: fileManager)
            }
            try? fileManager.removeItem(at: item)
            return
        }

        if !targetExists {
            try fileManager.moveItem(at: item, to: target)
        }
    }

    private static func migratedName(for legacyName: String) -> String {
        legacyName == "api-manager.log" ? "unigate.log" : legacyName
    }
}
