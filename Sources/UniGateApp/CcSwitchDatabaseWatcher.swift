import Darwin
import Foundation

final class CcSwitchDatabaseWatcher: @unchecked Sendable {
    private struct FileSignature: Equatable {
        let exists: Bool
        let size: UInt64
        let modifiedAt: TimeInterval
        let fileID: UInt64

        static func capture(path: String) -> FileSignature {
            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            else {
                return FileSignature(exists: false, size: 0, modifiedAt: 0, fileID: 0)
            }

            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            return FileSignature(exists: true, size: size, modifiedAt: modifiedAt, fileID: fileID)
        }
    }

    private struct DatabaseSignature: Equatable {
        let main: FileSignature
        let wal: FileSignature
        let shm: FileSignature

        static func capture(dbPath: String) -> DatabaseSignature {
            DatabaseSignature(
                main: FileSignature.capture(path: dbPath),
                wal: FileSignature.capture(path: "\(dbPath)-wal"),
                shm: FileSignature.capture(path: "\(dbPath)-shm")
            )
        }
    }

    private let queue = DispatchQueue(label: "unigate.cc-switch-db-watcher")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let debounceNanoseconds: UInt64
    private var source: DispatchSourceFileSystemObject?
    private var pendingWorkItem: DispatchWorkItem?
    private var watchedDBPath: String?
    private var watchedDirectoryPath: String?
    private var lastSignature: DatabaseSignature?

    init(debounceMilliseconds: UInt64 = 800) {
        self.debounceNanoseconds = debounceMilliseconds * 1_000_000
        queue.setSpecific(key: queueKey, value: true)
    }

    func start(dbPath: String, onChange: @escaping @Sendable () -> Void) {
        let expandedPath = (dbPath as NSString).expandingTildeInPath
        let directoryPath = (expandedPath as NSString).deletingLastPathComponent
        syncOnQueue { [self] in
            startOnQueue(dbPath: expandedPath, directoryPath: directoryPath, onChange: onChange)
        }
    }

    func stop() {
        syncOnQueue { [self] in
            stopOnQueue()
        }
    }

    func refreshBaseline(dbPath: String) {
        let expandedPath = (dbPath as NSString).expandingTildeInPath
        queue.async { [weak self] in
            guard self?.watchedDBPath == expandedPath else {
                return
            }
            self?.lastSignature = DatabaseSignature.capture(dbPath: expandedPath)
        }
    }

    private func syncOnQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private func startOnQueue(
        dbPath expandedPath: String,
        directoryPath: String,
        onChange: @escaping @Sendable () -> Void
    ) {
        if watchedDBPath == expandedPath, watchedDirectoryPath == directoryPath, source != nil {
            lastSignature = DatabaseSignature.capture(dbPath: expandedPath)
            return
        }

        stopOnQueue()

        let fd = open(directoryPath, O_EVTONLY)
        guard fd >= 0 else {
            return
        }

        watchedDBPath = expandedPath
        watchedDirectoryPath = directoryPath
        lastSignature = DatabaseSignature.capture(dbPath: expandedPath)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReloadIfDatabaseChanged(onChange: onChange)
        }
        source.setCancelHandler {
            close(fd)
        }
        self.source = source
        source.resume()
    }

    private func stopOnQueue() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        source?.cancel()
        source = nil
        watchedDBPath = nil
        watchedDirectoryPath = nil
        lastSignature = nil
    }

    private func scheduleReloadIfDatabaseChanged(onChange: @escaping @Sendable () -> Void) {
        pendingWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let watchedDBPath else {
                return
            }
            let nextSignature = DatabaseSignature.capture(dbPath: watchedDBPath)
            guard nextSignature != lastSignature else {
                return
            }
            lastSignature = nextSignature
            onChange()
        }
        pendingWorkItem = workItem
        queue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(debounceNanoseconds)),
            execute: workItem
        )
    }
}
