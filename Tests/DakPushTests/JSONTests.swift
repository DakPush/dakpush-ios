@testable import DakPush
import XCTest

final class JSONTests: XCTestCase {
    func testNullsAndBooleansSurvive() {
        let data = JSON.encode(["a": .null, "b": .bool(true), "c": .int(1), "d": .string("রহিম")])
        XCTAssertEqual(JSON.decodeObject(data), ["a": .null, "b": .bool(true), "c": .int(1), "d": .string("রহিম")])
    }
}
