import UniGateCore
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser.path
let dbPath = ProcessInfo.processInfo.environment["API_MANAGER_CC_SWITCH_DB"]
    ?? "\(home)/.cc-switch/cc-switch.db"

do {
    let catalog = try CcSwitchImporter(dbPath: dbPath).loadCatalog()
    let transformCandidates = catalog.candidates
        .filter(\.requiresTransform)
        .map { candidate in
            [
                "model": candidate.logicalModel,
                "provider": candidate.providerName,
                "apiFormat": candidate.apiFormat.rawValue
            ]
        }

    let summary: [String: Any] = [
        "dbPath": dbPath,
        "providerCount": catalog.providers.count,
        "modelCount": catalog.models.count,
        "candidateCount": catalog.candidates.count,
        "models": catalog.models,
        "transformCandidates": transformCandidates
    ]
    let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}

