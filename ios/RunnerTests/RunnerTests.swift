import Flutter
import UIKit
import XCTest
import Darwin
@testable import Runner

class RunnerTests: XCTestCase {

  func testDisplayPathKeepsFileIdentityWithoutContainerUUID() {
    let path = "/var/mobile/Containers/Data/Application/12345678-1234-1234-1234-123456789ABC/Runner.app/Frameworks/example.framework/example"
    let displayed = ResourceDiagnostics.displayPath(path)
    XCTAssertFalse(displayed.contains("12345678-1234-1234-1234-123456789ABC"))
    XCTAssertTrue(displayed.hasSuffix("Runner.app/Frameworks/example.framework/example"))
    XCTAssertEqual(ResourceDiagnostics.displayPath("/usr/lib/example.dylib"), "/usr/lib/example.dylib")
  }

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
