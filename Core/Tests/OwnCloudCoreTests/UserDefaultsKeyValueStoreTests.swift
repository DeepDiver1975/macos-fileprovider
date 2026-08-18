import XCTest
@testable import OwnCloudCore

/// Task 7.3: the production `KeyValueStore` adapter over `UserDefaults`. In the
/// app it is constructed with the app group suite name
/// (`group.com.owncloud.macos.fileprovider`) so the app and the extension share
/// the registry; here it runs over a throwaway suite.
final class UserDefaultsKeyValueStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        // A per-test suite so runs never collide; each is removed in teardown.
        suiteName = "test.owncloud.kvstore.\(name)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("Could not open a UserDefaults suite in this environment.")
        }
        self.defaults = defaults
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testWriteThenReadRoundTrips() {
        let store = UserDefaultsKeyValueStore(defaults: defaults)
        store.setData(Data([0x01, 0x02, 0x03]), forKey: "k")
        XCTAssertEqual(store.data(forKey: "k"), Data([0x01, 0x02, 0x03]))
    }

    func testAbsentKeyReadsAsNil() {
        let store = UserDefaultsKeyValueStore(defaults: defaults)
        XCTAssertNil(store.data(forKey: "missing"))
    }

    func testSettingNilRemovesTheKey() {
        let store = UserDefaultsKeyValueStore(defaults: defaults)
        store.setData(Data([0xFF]), forKey: "k")
        store.setData(nil, forKey: "k")
        XCTAssertNil(store.data(forKey: "k"))
    }
}
