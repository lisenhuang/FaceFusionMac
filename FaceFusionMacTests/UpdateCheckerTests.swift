import Foundation
import Testing
@testable import Morphiqo

@Suite("Mac App Store update lookup")
struct UpdateCheckerTests {

    @Test("ignores an iOS result returned for the shared bundle identifier")
    func ignoresIOSResult() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "results": [[
                "version": "9.9.9",
                "trackViewUrl": "https://apps.apple.com/app/id6797135085",
                "bundleId": "com.lisenhuang.morphiqo",
                "kind": "software"
            ]]
        ])

        #expect(UpdateChecker.parse(data) == nil)
    }

    @Test("accepts only the Mac listing")
    func acceptsMacResult() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "results": [[
                "version": "1.6.0",
                "trackViewUrl": "https://apps.apple.com/app/morphiqo/id1234567890",
                "bundleId": "com.lisenhuang.morphiqo",
                "kind": "mac-software"
            ]]
        ])

        let update = try #require(UpdateChecker.parse(data))
        #expect(update.version == "1.6.0")
        #expect(update.storeURL.absoluteString == "https://apps.apple.com/app/morphiqo/id1234567890")
    }
}
