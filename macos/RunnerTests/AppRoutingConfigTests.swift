import XCTest

final class AppRoutingConfigTests: XCTestCase {
  func testMatchesExactSigningIdentifierAndTeam() {
    let config = AppProxyConfiguration(dictionary: [
      "masterEnabled": true,
      "configurationHash": "abc",
      "rules": [[
        "id": "browser",
        "displayName": "Browser",
        "signingIdentifier": "example.browser",
        "helperSigningIdentifiers": ["example.browser.helper"],
        "teamIdentifier": "TEAM123",
        "interfaceId": "en8",
        "enabled": true,
        "failurePolicy": "block",
      ]],
    ])

    XCTAssertNotNil(config.match(signingIdentifier: "example.browser", teamIdentifier: "TEAM123"))
    XCTAssertNotNil(config.match(signingIdentifier: "example.browser.helper", teamIdentifier: "TEAM123"))
    XCTAssertNil(config.match(signingIdentifier: "example.browser", teamIdentifier: "OTHER"))
    XCTAssertNil(config.match(signingIdentifier: "example.other", teamIdentifier: "TEAM123"))
  }

  func testRejectsUtunAndDisabledMaster() {
    let config = AppProxyConfiguration(dictionary: [
      "masterEnabled": true,
      "rules": [[
        "id": "browser",
        "displayName": "Browser",
        "signingIdentifier": "example.browser",
        "teamIdentifier": "TEAM123",
        "interfaceId": "utun6",
      ]],
    ])
    XCTAssertTrue(config.rules.isEmpty)

    let disabled = AppProxyConfiguration(dictionary: [
      "masterEnabled": false,
      "rules": [[
        "id": "browser",
        "displayName": "Browser",
        "signingIdentifier": "example.browser",
        "teamIdentifier": "TEAM123",
        "interfaceId": "en0",
      ]],
    ])
    XCTAssertNil(disabled.match(signingIdentifier: "example.browser", teamIdentifier: "TEAM123"))
  }

  func testDecisionEngineRelaysBlocksAndFallsBack() {
    func configuration(policy: String) -> AppProxyConfiguration {
      AppProxyConfiguration(dictionary: [
        "masterEnabled": true,
        "rules": [[
          "id": "browser",
          "displayName": "Browser",
          "signingIdentifier": "example.browser",
          "teamIdentifier": "TEAM123",
          "interfaceId": "en8",
          "failurePolicy": policy,
        ]],
      ])
    }

    XCTAssertEqual(
      FlowDecisionEngine(configuration: configuration(policy: "block")).decision(
        signingIdentifier: "example.browser",
        teamIdentifier: "TEAM123",
        availablePhysicalInterfaces: ["en8"]
      ),
      .relay(ruleId: "browser", interfaceName: "en8")
    )
    XCTAssertEqual(
      FlowDecisionEngine(configuration: configuration(policy: "block")).decision(
        signingIdentifier: "example.browser",
        teamIdentifier: "TEAM123",
        availablePhysicalInterfaces: []
      ),
      .block(ruleId: "browser", interfaceName: "en8")
    )
    XCTAssertEqual(
      FlowDecisionEngine(configuration: configuration(policy: "fallback")).decision(
        signingIdentifier: "example.browser",
        teamIdentifier: "TEAM123",
        availablePhysicalInterfaces: []
      ),
      .direct
    )
  }
}
