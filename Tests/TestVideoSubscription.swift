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
    
    private func getQualities(discontinous: [Bool]) throws -> [VideoSubscription.SimulreceiveItem] {
        let highestBuffer = try testImage(width: 1920, height: 1280)
        let highestImage = AvailableImage(image: try .init(imageBuffer: highestBuffer,
                                                           formatDescription: .init(imageBuffer: highestBuffer),
                                                           sampleTiming: .init(duration: .invalid,
                                                                               presentationTimeStamp: .init(value: 1, timescale: 1),
                                                                               decodeTimeStamp: .invalid)),
                                          fps: 30,
                                          discontinous: discontinous[0])
        let highest = VideoSubscription.SimulreceiveItem(namespace: "1", image: highestImage)
        
        let mediumBuffer = try testImage(width: 1280, height: 960)
        let mediumImage = AvailableImage(image: try .init(imageBuffer: mediumBuffer,
                                                          formatDescription: .init(imageBuffer: mediumBuffer),
                                                          sampleTiming: .init(duration: .invalid,
                                                                              presentationTimeStamp: .init(value: 1, timescale: 1),
                                                                              decodeTimeStamp: .invalid)),
                                        fps: 30,
                                        discontinous: discontinous[1])
        let medium = VideoSubscription.SimulreceiveItem(namespace: "2", image: mediumImage)
        
        let lowerBuffer = try testImage(width: 1280, height: 960)
        let lowerImage = AvailableImage(image: try .init(imageBuffer: lowerBuffer,
                                                         formatDescription: .init(imageBuffer: lowerBuffer),
                                                         sampleTiming: .init(duration: .invalid,
                                                                             presentationTimeStamp: .init(value: 1, timescale: 1),
                                                                             decodeTimeStamp: .invalid)),
                                        fps: 30,
                                        discontinous: discontinous[2])
        let lower = VideoSubscription.SimulreceiveItem(namespace: "3", image: lowerImage)

        return [highest, medium, lower]
    }
    
    func testOnlyConsiderOldest() throws {
        // Only the subset of frames matching the oldest timestamp should be selected.
    }
    
    func testNothingGivesNothing() {
        XCTAssertNil(VideoSubscription.makeSimulreceiveDecision(choices: []))
    }
    
    func testOneReturnsItself() throws {
        let choices = try getQualities(discontinous: .init(repeating: false, count: 3))
        let result = VideoSubscription.makeSimulreceiveDecision(choices: [choices[0]])
        XCTAssertNotNil(result)
        XCTAssertEqual(result, choices[0])
    }
    
    func testHighestResolutionWhenAllPristine() throws {
        // When we have all available pristine images, highest quality should be picked.
        let choices = try getQualities(discontinous: .init(repeating: false, count: 3))
        let result = VideoSubscription.makeSimulreceiveDecision(choices: choices)
        XCTAssertNotNil(result)
        XCTAssertNotEqual(result, choices[1])
        XCTAssertNotEqual(result, choices[2])
        XCTAssertEqual(result, choices[0])
    }
    
    func testLowerPristineWhenHigherIsNot() throws {
        // When we have all available images, highest pristine should be picked.
        let choices = try getQualities(discontinous: [true, false, false])
        let result = VideoSubscription.makeSimulreceiveDecision(choices: choices)
        XCTAssertNotNil(result)
        XCTAssertNotEqual(result, choices[0])
        XCTAssertNotEqual(result, choices[2])
        XCTAssertEqual(result, choices[1])
    }
    
    func testAllDiscontinous() throws {
        // When we have all discontinous images, highest resolution should be picked.
        let choices = try getQualities(discontinous: .init(repeating: true, count: 3))
        let result = VideoSubscription.makeSimulreceiveDecision(choices: choices)
        XCTAssertNotNil(result)
        XCTAssertNotEqual(result, choices[1])
        XCTAssertNotEqual(result, choices[2])
        XCTAssertEqual(result, choices[0])
    }
}

extension VideoSubscription.SimulreceiveItem: Equatable {
    public static func == (lhs: VideoSubscription.SimulreceiveItem, rhs: VideoSubscription.SimulreceiveItem) -> Bool {
        lhs.image == rhs.image && lhs.namespace == rhs.namespace
    }
}

extension AvailableImage: Equatable {
    public static func == (lhs: AvailableImage, rhs: AvailableImage) -> Bool {
        lhs.image == rhs.image
    }
}
