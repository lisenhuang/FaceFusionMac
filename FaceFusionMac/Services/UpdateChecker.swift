//
//  UpdateChecker.swift
//  FaceFusionMac
//
//  Asks the App Store whether a newer build is on sale.
//
//  Two callers with opposite requirements, which is why there are two entry
//  points over one lookup:
//
//  `check()` is the launch pass, and is silent by construction. An offline
//  machine, a rate-limited lookup, a malformed answer and an app that is
//  already current all produce exactly the same result: nothing on screen,
//  nothing logged above debug. The only visible outcome is a version genuinely
//  newer than the one running.
//
//  `fetch()` is the Check for Updates button in Settings, and must say
//  something every time, because the user asked. It therefore keeps the three
//  outcomes `check()` flattens into `nil` apart — and on this platform that is
//  not a refinement, it is the whole point. See the note on the Mac listing
//  below: today the lookup can only ever come back empty, so a button built on
//  `check()` would answer "you are up to date" every time without ever having
//  learned anything. `.unavailable` is what stops it claiming that.
//
//  This is the second network request the app makes — `ModelManager` makes the
//  first — and the only one that is not about models. It sends the app's own
//  bundle identifier and nothing else: no machine identifier, no install identifier,
//  no usage, no media. The session is ephemeral, so the lookup leaves behind no
//  cache, cookie or credential.
//
//  Finding the Mac build in the store's answer is the whole difficulty, and the
//  obvious two ways of doing it are both wrong.
//
//  `entity=macSoftware` does not filter. `entity` is honoured by `/search` and
//  ignored by `/lookup`: ask `/lookup` about an iOS-only bundle id with
//  `entity=macSoftware` and it returns the iOS record anyway. The parameter is
//  kept because it costs nothing and states the intent, but nothing may rest
//  on it.
//
//  `kind == "mac-software"` does not match us either, and for a while this file
//  required it — which meant the Mac's update check could never succeed. That
//  kind identifies an app with its own *separate* Mac App Store listing.
//  Morphiqo is a Universal Purchase: one record (id 6797135085) covering
//  iPhone, iPad, Mac and Vision, whose `kind` is `software` because the record
//  is primarily the iOS one. There is no second record to find, and searching
//  `entity=macSoftware` for it returns nothing.
//
//  What does identify us is `MacDesktop-MacDesktop` in `supportedDevices`.
//  Checked against both neighbours it is exactly the right signal: an app with
//  a separate Mac listing reports `kind == "mac-software"` and no `MacDesktop`
//  entry, and an iPad app merely runnable on Apple silicon — the "Designed for
//  iPad, not verified for macOS" case — reports `kind == "software"` and no
//  `MacDesktop` entry either. Only a record containing a real Mac build has it.
//
//  So `parse` accepts either shape, and still refuses a plain iOS record. What
//  it cannot do is tell the two platforms' *versions* apart: one record carries
//  one public version number, and it is the iOS one. That is only harmless
//  while the two projects are released at the same marketing version — see
//  `CLAUDE.md`, which is where that requirement is written down.
//

import Foundation
import os

enum UpdateChecker {

    /// The Mac app's bundle identifier. Looking up by bundle ID lets Apple
    /// return the Mac record when it exists without hard-coding the iOS app's
    /// numeric App Store ID.
    private static let appBundleID = "com.lisenhuang.morphiqo"

    /// What the store is selling, on the occasions it is ahead of us.
    struct Update: Equatable, Sendable {
        let version: String
        let storeURL: URL
    }

    /// Everything a lookup can conclude, for the caller that has to report all
    /// of them rather than only the interesting one.
    enum Outcome: Equatable, Sendable {
        /// The store answered, and what it is selling is not newer than this
        /// build. Carries the store's own number rather than echoing the
        /// installed one, because a locally built copy is ahead of the listing
        /// and saying so is more use than pretending otherwise.
        case current(latest: String)

        /// The store answered, and it is ahead of us.
        case available(Update)

        /// No usable answer: offline, rate-limited, malformed, or — the case
        /// that applies to every Mac today — no listing for this platform.
        /// Deliberately not split further: none of the causes change what the
        /// user can do about it, and none of them are evidence that this build
        /// is current.
        case unavailable
    }

    /// The version this build reports, for the "you have…" half of the prompt.
    static var installedVersion: String {
        marketingVersion ?? "—"
    }

    /// The same value, but only when it is something a comparison can be based
    /// on. An `Info.plist` without it would otherwise compare against the em
    /// dash above and make every listing look like an upgrade.
    private static var marketingVersion: String? {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty else { return nil }
        return version
    }

    /// `nil` for every outcome except "something newer is on sale".
    ///
    /// Deliberately never throws and never reports a failure to the caller:
    /// a version check that interrupts someone because a network was flaky is
    /// worse than one that quietly does nothing.
    static func check() async -> Update? {
        guard case .available(let update) = await fetch() else { return nil }
        return update
    }

    /// The same lookup, with the outcomes kept apart.
    static func fetch() async -> Outcome {
        guard let installed = marketingVersion else { return .unavailable }
        let outcome = outcome(for: await lookup(), installed: installed)

        switch outcome {
        case .unavailable:
            EngineLog.client.debug("Update check: no answer from the store")
        case .current:
            EngineLog.client.debug("Update check: \(installed, privacy: .public) is current")
        case .available(let update):
            EngineLog.client.notice("Update available: \(update.version, privacy: .public)")
        }
        return outcome
    }

    /// The decision itself, as a pure function of what the store said and what
    /// this build is — so the comparison rule below can be tested without a
    /// network, which is the only way it ever gets tested at all.
    static func outcome(for listing: Update?, installed: String) -> Outcome {
        guard let listing else { return .unavailable }

        // `.numeric` compares run by run rather than character by character, so
        // 1.0.10 sorts above 1.0.9 — which a plain string comparison gets
        // backwards, and gets backwards silently.
        guard listing.version.compare(installed, options: .numeric) == .orderedDescending else {
            return .current(latest: listing.version)
        }
        return .available(listing)
    }

    // MARK: - Lookup

    /// The storefront matters: an app is listed per country, and the default US
    /// storefront answers about an app that may not be sold there. Ask about the
    /// user's region first, then fall back — a region the store does not know is
    /// answered with an empty result rather than an error, so the fallback is
    /// what makes the check work outside the United States.
    private static func lookup() async -> Update? {
        if let region = Locale.current.region?.identifier,
           let found = await lookup(country: region) {
            return found
        }
        return await lookup(country: nil)
    }

    private static func lookup(country: String?) async -> Update? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        var items = [URLQueryItem(name: "bundleId", value: appBundleID),
                     URLQueryItem(name: "entity", value: "macSoftware")]
        if let country { items.append(URLQueryItem(name: "country", value: country)) }
        components?.queryItems = items
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return parse(data)
        } catch {
            EngineLog.client.debug("Update check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func parse(_ data: Data) -> Update? {
        struct Payload: Decodable {
            struct Entry: Decodable {
                let version: String
                let trackViewUrl: String
                let bundleId: String
                let kind: String
                /// Absent from a `mac-software` record, which does not need it.
                let supportedDevices: [String]?

                /// Whether this record contains a build that runs on a Mac.
                ///
                /// Two shapes qualify and a third must not. A separate Mac App
                /// Store listing announces itself by `kind`. A Universal
                /// Purchase — which is what we are — announces itself only by
                /// carrying the Mac device in an otherwise iOS-shaped record.
                /// An iPad app that Apple silicon merely happens to be able to
                /// run has neither, and is the case this has to keep rejecting.
                var includesMacBuild: Bool {
                    kind == "mac-software"
                        || (supportedDevices ?? []).contains("MacDesktop-MacDesktop")
                }
            }
            let results: [Entry]
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let entry = payload.results.first(where: {
                  $0.bundleId == appBundleID && $0.includesMacBuild
              }),
              let url = URL(string: entry.trackViewUrl) else { return nil }
        return Update(version: entry.version, storeURL: url)
    }

    /// Ephemeral, so nothing about the lookup is written to disk, and
    /// non-waiting, so it gives up rather than queueing itself against some
    /// later moment when connectivity returns and the user has moved on.
    ///
    /// Ephemeral is not the same as uncached: the session still keeps a URL
    /// cache in memory, and it is a `static let`, so it lives as long as the
    /// process does. That did not matter while the only caller ran once per
    /// launch. It matters now that a button can ask again — a second check
    /// would be answered by the first one's stored response instead of by the
    /// store, and pressing Check for Updates would be unable to notice anything
    /// had changed. Refusing the local cache is what makes the button mean what
    /// it says.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}
