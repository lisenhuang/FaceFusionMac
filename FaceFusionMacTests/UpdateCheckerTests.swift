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

    /// The shape Morphiqo actually has. One Universal Purchase record covering
    /// iPhone, iPad, Mac and Vision: `kind` is `software`, because the record is
    /// primarily the iOS one, and the only thing announcing the Mac build is the
    /// device in `supportedDevices`. Requiring `kind == "mac-software"` here
    /// meant the Mac could never find its own listing.
    @Test("accepts the Universal Purchase record that carries the Mac build")
    func acceptsUniversalPurchaseRecord() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "results": [[
                "version": "1.9.0",
                "trackViewUrl": "https://apps.apple.com/app/id6797135085",
                "bundleId": "com.lisenhuang.morphiqo",
                "kind": "software",
                "supportedDevices": ["iPhone5s-iPhone5s", "MacDesktop-MacDesktop"]
            ]]
        ])

        let update = try #require(UpdateChecker.parse(data))
        #expect(update.version == "1.9.0")
    }

    /// The case that must keep being rejected: an iPad app Apple silicon merely
    /// happens to be able to run — "Designed for iPad, not verified for macOS".
    /// It looks exactly like the record above apart from the missing device, so
    /// that device is the whole test.
    @Test("ignores an iOS record with no Mac build in it")
    func ignoresIOSOnlyRecordWithDevices() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "results": [[
                "version": "9.9.9",
                "trackViewUrl": "https://apps.apple.com/app/id6797135085",
                "bundleId": "com.lisenhuang.morphiqo",
                "kind": "software",
                "supportedDevices": ["iPhone5s-iPhone5s", "iPadAir-iPadAir"]
            ]]
        ])

        #expect(UpdateChecker.parse(data) == nil)
    }

    // MARK: - What the manual check concludes

    private static func listing(_ version: String) -> UpdateChecker.Update {
        UpdateChecker.Update(version: version,
                             storeURL: URL(string: "https://apps.apple.com/app/id1234567890")!)
    }

    /// The case every Mac hits today. There is no Mac listing, so `parse`
    /// rejects the iOS record the lookup returns and there is nothing to
    /// compare against — which must not be reported as "up to date". The
    /// Settings button's whole honesty rests on this.
    @Test("no answer from the store is never reported as up to date")
    func noAnswerIsNotCurrent() {
        #expect(UpdateChecker.outcome(for: nil, installed: "1.9.0") == .unavailable)
    }

    @Test("a newer listing is an available update")
    func newerListing() {
        #expect(UpdateChecker.outcome(for: Self.listing("1.9.1"), installed: "1.9.0")
                == .available(Self.listing("1.9.1")))
    }

    @Test("the same version is current")
    func sameVersion() {
        #expect(UpdateChecker.outcome(for: Self.listing("1.9.0"), installed: "1.9.0")
                == .current(latest: "1.9.0"))
    }

    /// A locally built copy runs ahead of the listing. It is current, and the
    /// number reported is the store's rather than its own.
    @Test("a build ahead of the listing is current, and says what the store has")
    func buildAheadOfListing() {
        #expect(UpdateChecker.outcome(for: Self.listing("1.9.0"), installed: "1.10.0")
                == .current(latest: "1.9.0"))
    }

    /// The reason the comparison is `.numeric`. Character by character, "9"
    /// sorts above "1", so 1.0.9 would look newer than 1.0.10 — and would do it
    /// silently, by never offering an update that exists.
    @Test("version runs compare numerically, not character by character")
    func numericComparison() {
        #expect(UpdateChecker.outcome(for: Self.listing("1.0.10"), installed: "1.0.9")
                == .available(Self.listing("1.0.10")))
        #expect(UpdateChecker.outcome(for: Self.listing("1.0.9"), installed: "1.0.10")
                == .current(latest: "1.0.9"))
    }
}
