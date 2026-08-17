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
//  `entity=macSoftware` asks about the Mac listing specifically, and does not
//  get it. `entity` is honoured by `/search` and ignored by `/lookup`: asking
//  `/lookup` about an iOS-only bundle id with `entity=macSoftware` returns the
//  iOS record regardless. The `kind == "mac-software"` test in `parse` is
//  therefore the only thing standing between this window and an alert offering
//  the Mac the iPhone app's version number. Keep the parameter — it costs
//  nothing and documents the intent — but do not rely on it.
//
//  As of writing there is no Mac listing at all: the app ships as a DMG, and a
//  store search for it returns nothing, so `parse` rejects the iOS record it is
//  handed and every lookup resolves to `.unavailable`. That is the correct
//  answer rather than a broken one, and it is why the button reports "could not
//  check" instead of "up to date". If a Mac record ever appears, this starts
//  working with no change here. If the DMG remains the distribution channel,
//  the honest fix is to ask GitHub Releases for the latest tag instead of
//  asking Apple — a different `lookup()`, and nothing else on this screen.
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
            }
            let results: [Entry]
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let entry = payload.results.first(where: {
                  $0.bundleId == appBundleID && $0.kind == "mac-software"
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
