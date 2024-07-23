@testable import Decimus
import XCTest

typealias View = NumberView<UInt16>

final class TestNumberView: XCTestCase {
    func testValidation() throws {
        typealias View = NumberView<UInt16>
        let view = View(value: .constant(0), formatStyle: IntegerFormatStyle<UInt16>.number.grouping(.never), name: "Size")

        // Not a number.
        let nonNumber = try view.validate("abcd")
        XCTAssertEqual(nonNumber, View.ValidationResult.nan)

        // Empty.
        let empty = try view.validate("")
        XCTAssertEqual(empty, View.ValidationResult.empty)

        // Valid.
        let value = UInt16.random(in: UInt16.min...UInt16.max)
        let valid = try view.validate(String(value))
        switch valid {
        case .valid(let result):
            XCTAssertEqual(value, result)
        default:
            XCTFail("\(value) should be valid but was: \(valid)")
        }

        // Too large.
        let plusOne = UInt32(UInt16.max) + 1
        let result = try view.validate(String(plusOne))
        XCTAssertEqual(result, View.ValidationResult.tooLarge)
    }
}
