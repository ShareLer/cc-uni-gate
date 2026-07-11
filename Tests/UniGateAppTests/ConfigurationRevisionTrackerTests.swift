@testable import UniGateApp
import Testing

struct ConfigurationRevisionTrackerTests {
    @Test
    func invalidationRejectsTokensCapturedBeforeConfigurationReload() {
        var tracker = ConfigurationRevisionTracker()
        let staleRevision = tracker.current

        tracker.invalidate()

        #expect(!tracker.isCurrent(staleRevision))
        #expect(tracker.isCurrent(tracker.current))
    }
}
