struct ConfigurationRevisionTracker {
    private(set) var current: UInt64 = 0

    mutating func invalidate() {
        current &+= 1
    }

    func isCurrent(_ revision: UInt64) -> Bool {
        revision == current
    }
}
