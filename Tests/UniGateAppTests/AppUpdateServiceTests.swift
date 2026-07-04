@testable import UniGateApp
import Foundation
import Testing

struct AppUpdateServiceTests {
    @Test
    func recognizesSparkleNoUpdateError() {
        let error = NSError(
            domain: "SUSparkleErrorDomain",
            code: 1001,
            userInfo: [NSLocalizedDescriptionKey: "You’re up to date!"]
        )

        #expect(AppUpdateService.isNoUpdateError(error))
    }

    @Test
    func doesNotTreatOtherErrorsAsNoUpdate() {
        let error = NSError(
            domain: "SUSparkleErrorDomain",
            code: 2001,
            userInfo: [NSLocalizedDescriptionKey: "Network failure"]
        )

        #expect(!AppUpdateService.isNoUpdateError(error))
    }
}
