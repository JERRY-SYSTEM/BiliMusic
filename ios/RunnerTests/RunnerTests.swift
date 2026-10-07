import Flutter
import UIKit
import XCTest
import Darwin
@testable import Runner

class RunnerTests: XCTestCase {

  func testSnapshotObservesPipesWithoutClosingThem() {
    var descriptors = [Int32](repeating: -1, count: 2)
    XCTAssertEqual(descriptors.withUnsafeMutableBufferPointer { pipe($0.baseAddress!) }, 0)
    defer { for fd in descriptors where fd >= 0 { close(fd) } }
    let snapshot = ResourceDiagnostics.snapshot()
    let categories = snapshot["categories"] as? [String: Int]
    XCTAssertGreaterThanOrEqual(categories?["pipe"] ?? 0, 2)
    for fd in descriptors { XCTAssertGreaterThanOrEqual(fcntl(fd, F_GETFD), 0) }
    XCTAssertNotNil(snapshot["softLimit"])
  }

}
