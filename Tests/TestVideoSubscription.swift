@testable import Decimus
import Foundation
import XCTest
import CoreMedia

final class TestVideoSubscription: XCTestCase {
    private func testImage(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCMPixelFormat_24RGB,
                                         nil,
                                         &buffer)
        guard result == .zero,
              let buffer = buffer else { throw "Failed: \(result)" }
        return buffer
    }

    private func getQualities(discontinous: [Bool], timing: [CMTime]? = nil) throws -> [VideoSubscription.SimulreceiveItem] {
        let highestBuffer = try testImage(width: 1920, height: 1280)
        let highestImage = AvailableImage(image: try .init(imageBuffer: highestBuffer,
                                                           formatDescription: .init(imageBuffer: highestBuffer),
                                                           sampleTiming: .init(duration: .invalid,
                                                                               presentationTimeStamp: timing?[0] ?? .init(value: 1, timescale: 1),
                                                                               decodeTimeStamp: .invalid)),
                                          fps: 30,
                                          discontinous: discontinous[0])
        let highest = VideoSubscription.SimulreceiveItem(namespace: "1", image: highestImage)

        let mediumBuffer = try testImage(width: 1280, height: 960)
        let mediumImage = AvailableImage(image: try .init(imageBuffer: mediumBuffer,
                                                          formatDescription: .init(imageBuffer: mediumBuffer),
                                                          sampleTiming: .init(duration: .invalid,
                                                                              presentationTimeStamp: timing?[1] ?? .init(value: 1, timescale: 1),
                                                                              decodeTimeStamp: .invalid)),
                                        fps: 30,
                                        discontinous: discontinous[1])
        let medium = VideoSubscription.SimulreceiveItem(namespace: "2", image: mediumImage)

        let lowerBuffer = try testImage(width: 1280, height: 960)
        let lowerImage = AvailableImage(image: try .init(imageBuffer: lowerBuffer,
                                                         formatDescription: .init(imageBuffer: lowerBuffer),
                                                         sampleTiming: .init(duration: .invalid,
                                                                             presentationTimeStamp: timing?[2] ?? .init(value: 1, timescale: 1),
                                                                             decodeTimeStamp: .invalid)),
                                        fps: 30,
                                        discontinous: discontinous[2])
        let lower = VideoSubscription.SimulreceiveItem(namespace: "3", image: lowerImage)

        return [highest, medium, lower]
    }

    func testOnlyConsiderOldest() throws {
        // Only the subset of frames matching the oldest timestamp should be considered.
        let choices = try getQualities(discontinous: .init(repeating: false, count: 3),
                                       timing: [.init(value: 2, timescale: 1),
                                                .init(value: 1, timescale: 1),
                                                .init(value: 1, timescale: 1)])
        var inOutChoices = choices as any Collection<VideoSubscription.SimulreceiveItem>
        let result = VideoSubscription.makeSimulreceiveDecision(choices: &inOutChoices)
        XCTAssertNotNil(result)
        switch result {
        case .highestRes(let item, _):
            XCTAssertEqual(item, choices[1])
        default:
            XCTFail()
        }

    }

    func testNothingGivesNothing() {
        let choices: [VideoSubscription.SimulreceiveItem] = []
        var inOutChoices = choices as any Collection<VideoSubscription.SimulreceiveItem>
        XCTAssertNil(VideoSubscription.makeSimulreceiveDecision(choices: &inOutChoices))
    }

    func testOneReturnsItself() throws {
        let all = try getQualities(discontinous: .init(repeating: false, count: 3))
        let choices = [all[0]]
        var inOutChoices = choices as any Collection<VideoSubscription.SimulreceiveItem>
        let result = VideoSubscription.makeSimulreceiveDecision(choices: &inOutChoices)
        XCTAssertNotNil(result)
        switch result {
        case .onlyChoice(let item):
            XCTAssertEqual(item, choices[0])
        default:
            XCTFail()
        }
    }

    func testHighestResolutionWhenAllPristine() throws {
        // When we have all available pristine images, highest quality should be picked.
        let choices = try getQualities(discontinous: .init(repeating: false, count: 3))
        var inOutChoices = choices as any Collection<VideoSubscription.SimulreceiveItem>
        let result = VideoSubscription.makeSimulreceiveDecision(choices: &inOutChoices)
        XCTAssertNotNil(result)
        switch result {
        case .highestRes(let item, let pristine):
            XCTAssertNotEqual(item, choices[1])
            XCTAssertNotEqual(item, choices[2])
            XCTAssertEqual(item, choices[0])
            XCTAssert(pristine)
        default:
            XCTFail()
        }
    }

    func testLowerPristineWhenHigherIsNot() throws {
        // When we have all available images, highest pristine should be picked.
        let choices = try getQualities(discontinous: [true, false, false])
        var inOutChoices = choices as any Collection<VideoSubscription.SimulreceiveItem>
        let result = VideoSubscription.makeSimulreceiveDecision(choices: &inOutChoices)
        XCTAssertNotNil(result)
        switch result {
        case .highestRes(let item, let pristine):
            XCTAssertNotEqual(item, choices[0])
            XCTAssertNotEqual(item, choices[2])
            XCTAssertEqual(item, choices[1])
            XCTAssert(pristine)
        default:
            XCTFail()
        }
    }

    func testAllDiscontinous() throws {
        // When we have all discontinous images, highest resolution should be picked.
        let choices = try getQualities(discontinous: .init(repeating: true, count: 3))
        var inOutChoices = choices as any Collection<VideoSubscription.SimulreceiveItem>
        let result = VideoSubscription.makeSimulreceiveDecision(choices: &inOutChoices)
        XCTAssertNotNil(result)
        switch result {
        case .highestRes(let item, let pristine):
            XCTAssertFalse(pristine)
            XCTAssertNotEqual(item, choices[1])
            XCTAssertNotEqual(item, choices[2])
            XCTAssertEqual(item, choices[0])
        default:
            XCTFail()
        }
    }
}

extension AvailableImage: Equatable {
    public static func == (lhs: AvailableImage, rhs: AvailableImage) -> Bool {
        lhs.image == rhs.image
    }
}
