import Cocoa
import FlutterMacOS
import XCTest

@testable import netpilot_desktop

class RunnerTests: XCTestCase {
  func testRouteSpecValidation() {
    let ok = RouteSpec(
      destination: "10.0.0.1/32",
      gateway: "10.0.0.1",
      interfaceName: "en7",
      tag: "netpilot:abc"
    )
    XCTAssertNil(RouteSpec.validate(ok))
  }
}
