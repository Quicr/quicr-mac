@testable import Decimus
import XCTest

final class TestVarianceCalculator: XCTestCase {
    func testCalculator() throws {
        let expectedOccurrences = Int.random(in: .zero ..< 1000)
        let calculator = try VarianceCalculator(expectedOccurrences: expectedOccurrences, max: 10)
        let timestamp: TimeInterval = 1

        // We shouldn't get any result when we haven't reached the expected number yet.
        var now = Date.now
        for _ in 0..<expectedOccurrences - 1 {
            // No calculation yet.
            let nilResult = calculator.calculateSetVariance(timestamp: timestamp, now: now)
            now = now.addingTimeInterval(1)
            XCTAssertNil(nilResult)
        }

        // Now that we've reached the expected number, we should get a result.
        let result = calculator.calculateSetVariance(timestamp: timestamp, now: now)
        XCTAssertEqual(result, TimeInterval(expectedOccurrences - 1))
    }
}
