import XCTest
@testable import EyeGuardCore

final class AppDataPathTests: XCTestCase {
    func testEyeGuardDataPathsUseNewAppIdentity() {
        let root = URL(fileURLWithPath: "/tmp/Application Support")
        let paths = AppDataPaths(applicationSupportRoot: root)

        XCTAssertEqual(paths.appSupportURL.path, "/tmp/Application Support/com.eyeguard.app")
        XCTAssertEqual(paths.databaseURL.lastPathComponent, "eyeguard_stats.db")
        XCTAssertEqual(paths.logsDirectoryURL.lastPathComponent, "logs")
        XCTAssertEqual(paths.sessionStateURL.lastPathComponent, "current_session.json")
    }
}
