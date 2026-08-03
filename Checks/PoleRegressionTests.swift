import XCTest

final class PoleRegressionTests: XCTestCase {
    func testCompleteRegressionSuite() {
        XCTAssertEqual(runPoleRegressionChecks(), 0)
    }
}
