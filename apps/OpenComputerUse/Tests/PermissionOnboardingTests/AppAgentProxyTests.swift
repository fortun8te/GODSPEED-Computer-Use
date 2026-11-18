import XCTest
@testable import OpenComputerUse

final class AppAgentProxyTests: XCTestCase {
    func testMCPProxiesFromTheSameParentHaveSeparateDefaultIdentities() {
        let first = MacOSAppAgentProxy.proxyClientID(explicit: nil, mcp: true, processID: 101, parentProcessID: 99)
        let second = MacOSAppAgentProxy.proxyClientID(explicit: "", mcp: true, processID: 102, parentProcessID: 99)
        XCTAssertEqual(first, "p101")
        XCTAssertEqual(second, "p102")
    }

    func testCLIUsesParentIdentityAndExplicitIdentityCanShareState() {
        XCTAssertEqual(
            MacOSAppAgentProxy.proxyClientID(explicit: nil, mcp: false, processID: 101, parentProcessID: 99),
            "p99"
        )
        XCTAssertEqual(
            MacOSAppAgentProxy.proxyClientID(explicit: "shared", mcp: true, processID: 102, parentProcessID: 99),
            "shared"
        )
    }
}
