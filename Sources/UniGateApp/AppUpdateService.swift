import Foundation
import Sparkle

private let appUpdateNoUpdateErrorCode = 1001

@MainActor
enum AppUpdatePhase: Equatable {
    case unavailable(message: String)
    case idle
    case checking
    case noUpdate(message: String)
    case available(UpdateSnapshot)
    case downloading(UpdateSnapshot, expectedBytes: UInt64?, downloadedBytes: UInt64)
    case installing(UpdateSnapshot)
    case failed(UpdateSnapshot?, message: String)
}

enum AppUpdateConfigurationError: LocalizedError, Equatable {
    case missingConfiguration
    case incompleteConfiguration
    case invalidFeedURL
    case invalidPublicKey

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "未配置更新源。"
        case .incompleteConfiguration:
            return "更新源配置不完整。"
        case .invalidFeedURL:
            return "更新源 URL 配置无效。"
        case .invalidPublicKey:
            return "更新公钥配置无效。"
        }
    }
}

@MainActor
struct UpdateSnapshot: Equatable {
    let version: String
    let displayVersion: String
    let title: String?
    let releaseNotesURL: URL?
}

@MainActor
protocol AppUpdateServiceDelegate: AnyObject {
    func appUpdateService(_ service: AppUpdateService, didChangePhase phase: AppUpdatePhase)
}

@MainActor
final class AppUpdateService: NSObject {
    private let availabilityTimeoutNanoseconds: UInt64
    private let userDriver: AppUpdateUserDriver
    private var updater: SPUUpdater!
    private var availabilityResetTask: Task<Void, Never>?
    private var phase: AppUpdatePhase = .idle {
        didSet {
            delegate?.appUpdateService(self, didChangePhase: phase)
        }
    }

    weak var delegate: AppUpdateServiceDelegate?

    init(
        hostBundle: Bundle = .main,
        applicationBundle: Bundle = .main,
        availabilityTimeout: TimeInterval = 15 * 60
    ) throws {
        try Self.validateConfiguration(in: hostBundle)

        availabilityTimeoutNanoseconds = UInt64(max(availabilityTimeout, 1) * 1_000_000_000)
        userDriver = AppUpdateUserDriver()
        super.init()

        userDriver.owner = self
        updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: applicationBundle,
            userDriver: userDriver,
            delegate: self
        )
        do {
            try updater.start()
        } catch {
            throw error
        }
    }

    var currentPhase: AppUpdatePhase {
        phase
    }

    static func validateConfiguration(in bundle: Bundle) throws {
        let feedURLString = trimmedInfoString("SUFeedURL", in: bundle)
        let publicKey = trimmedInfoString("SUPublicEDKey", in: bundle)

        switch (feedURLString, publicKey) {
        case (nil, nil):
            throw AppUpdateConfigurationError.missingConfiguration
        case (nil, _), (_, nil):
            throw AppUpdateConfigurationError.incompleteConfiguration
        case let (.some(feedURLString), .some(publicKey)):
            guard let feedURL = URL(string: feedURLString), isValidFeedURL(feedURL) else {
                throw AppUpdateConfigurationError.invalidFeedURL
            }
            guard let keyData = Data(base64Encoded: publicKey, options: []), keyData.count == 32 else {
                throw AppUpdateConfigurationError.invalidPublicKey
            }
        }
    }

    var canCheckForUpdates: Bool {
        switch phase {
        case .checking, .downloading, .installing:
            return false
        case .unavailable, .idle, .noUpdate, .available, .failed:
            return updater.canCheckForUpdates
        }
    }

    func checkForUpdates() {
        guard updater.canCheckForUpdates else {
            return
        }
        cancelAvailabilityReset()
        transition(to: .checking)
        updater.checkForUpdateInformation()
    }

    func installAvailableUpdate() {
        guard case .available = phase, updater.canCheckForUpdates else {
            return
        }
        cancelAvailabilityReset()
        transition(to: .checking)
        updater.checkForUpdates()
    }

    func markUnavailable(_ message: String) {
        cancelAvailabilityReset()
        transition(to: .unavailable(message: message))
    }

    fileprivate func transition(to newPhase: AppUpdatePhase) {
        phase = newPhase
    }

    fileprivate func snapshot(for item: SUAppcastItem) -> UpdateSnapshot {
        UpdateSnapshot(
            version: item.versionString,
            displayVersion: item.displayVersionString,
            title: item.title,
            releaseNotesURL: item.fullReleaseNotesURL ?? item.releaseNotesURL
        )
    }

    fileprivate func cancelAvailabilityReset() {
        availabilityResetTask?.cancel()
        availabilityResetTask = nil
    }

    fileprivate func beginAvailabilityReset(for snapshot: UpdateSnapshot) {
        cancelAvailabilityReset()
        availabilityResetTask = Task { [weak self] in
            guard let self else {
                return
            }
            try? await Task.sleep(nanoseconds: self.availabilityTimeoutNanoseconds)
            guard case let .available(current) = phase, current == snapshot else {
                return
            }
            transition(to: .idle)
        }
    }

    fileprivate func normalizedErrorMessage(_ error: Error) -> String {
        let description = (error as NSError).localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "更新失败" : description
    }

    nonisolated static func isNoUpdateError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SUSparkleErrorDomain && nsError.code == appUpdateNoUpdateErrorCode
    }

    fileprivate func failureSnapshot() -> UpdateSnapshot? {
        switch phase {
        case let .available(snapshot),
             let .downloading(snapshot, _, _),
             let .installing(snapshot):
            return snapshot
        case let .failed(snapshot, _):
            return snapshot
        case .unavailable, .idle, .checking, .noUpdate:
            return nil
        }
    }

    private static func trimmedInfoString(_ key: String, in bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isValidFeedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return false
        }
        if scheme == "http" || scheme == "https" {
            return url.host?.isEmpty == false
        }
        if scheme == "file" {
            return !url.path.isEmpty
        }
        return true
    }
}

@MainActor
extension AppUpdateService: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let snapshot = snapshot(for: item)
        transition(to: .available(snapshot))
        beginAvailabilityReset(for: snapshot)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        cancelAvailabilityReset()
        transition(to: .noUpdate(message: "未发现新版本。当前已经是最新版本。"))
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if Self.isNoUpdateError(error) {
            cancelAvailabilityReset()
            transition(to: .noUpdate(message: "未发现新版本。当前已经是最新版本。"))
            return
        }
        cancelAvailabilityReset()
        transition(to: .failed(failureSnapshot(), message: normalizedErrorMessage(error)))
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if let error {
            if Self.isNoUpdateError(error) {
                cancelAvailabilityReset()
                transition(to: .noUpdate(message: "未发现新版本。当前已经是最新版本。"))
                return
            }
            cancelAvailabilityReset()
            transition(to: .failed(failureSnapshot(), message: normalizedErrorMessage(error)))
            return
        }

        if case .checking = phase {
            transition(to: .noUpdate(message: "未发现新版本。当前已经是最新版本。"))
        }
    }
}

@MainActor
private final class AppUpdateUserDriver: NSObject, SPUUserDriver {
    weak var owner: AppUpdateService?

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: false,
            automaticUpdateDownloading: NSNumber(value: false),
            sendSystemProfile: false
        ))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        owner?.transition(to: .checking)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        guard let owner else {
            reply(.dismiss)
            return
        }

        let snapshot = owner.snapshot(for: appcastItem)

        if appcastItem.isInformationOnlyUpdate {
            owner.transition(to: .available(snapshot))
            owner.beginAvailabilityReset(for: snapshot)
            reply(.dismiss)
            return
        }

        switch state.stage {
        case .notDownloaded, .downloaded:
            owner.transition(to: .downloading(snapshot, expectedBytes: nil, downloadedBytes: 0))
            reply(.install)
        case .installing:
            owner.transition(to: .installing(snapshot))
            reply(.install)
        @unknown default:
            owner.transition(to: .downloading(snapshot, expectedBytes: nil, downloadedBytes: 0))
            reply(.install)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner?.transition(to: .noUpdate(message: "未发现新版本。当前已经是最新版本。"))
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if let owner {
            owner.cancelAvailabilityReset()
            owner.transition(to: .failed(owner.failureSnapshot(), message: owner.normalizedErrorMessage(error)))
        }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        guard let owner else {
            return
        }
        switch owner.currentPhase {
        case let .available(snapshot), let .failed(.some(snapshot), _):
            owner.transition(to: .downloading(snapshot, expectedBytes: nil, downloadedBytes: 0))
        case .checking, .downloading, .installing, .idle, .noUpdate, .failed(nil, _), .unavailable:
            break
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard let owner,
              case let .downloading(snapshot, _, downloadedBytes) = owner.currentPhase else {
            return
        }
        owner.transition(to: .downloading(snapshot, expectedBytes: expectedContentLength, downloadedBytes: downloadedBytes))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard let owner else {
            return
        }
        switch owner.currentPhase {
        case let .downloading(snapshot, expectedBytes, downloadedBytes):
            owner.transition(
                to: .downloading(
                    snapshot,
                    expectedBytes: expectedBytes,
                    downloadedBytes: downloadedBytes + length
                )
            )
        case let .available(snapshot):
            owner.transition(to: .downloading(snapshot, expectedBytes: nil, downloadedBytes: length))
        default:
            break
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        guard let owner else {
            return
        }
        switch owner.currentPhase {
        case let .downloading(snapshot, _, _), let .available(snapshot):
            owner.transition(to: .installing(snapshot))
        default:
            break
        }
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.install)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        guard let owner else {
            return
        }
        switch owner.currentPhase {
        case let .downloading(snapshot, _, _), let .available(snapshot):
            owner.transition(to: .installing(snapshot))
        default:
            break
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {}

    func showUpdateInFocus() {}
}
