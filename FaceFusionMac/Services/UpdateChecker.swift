//
//  UpdateChecker.swift
//  FaceFusionMac
//
//  Asks the App Store, once per launch, whether a newer build is on sale.
//
//  Silent by construction. An offline machine, a rate-limited lookup, a
//  malformed answer and an app that is already current all produce exactly the
//  same result: nothing on screen, nothing logged above debug. The only visible
//  outcome is a version genuinely newer than the one running.
//
//  This is the second network request the app makes — `ModelManager` makes the
//  first — and the only one that is not about models. It sends the app's own
//  App Store id and nothing else: no machine identifier, no install identifier,
//  no usage, no media. The session is ephemeral, so the lookup leaves behind no
//  cache, cookie or credential.
//
//  `entity=macSoftware` asks about the Mac listing specifically. Until the Mac
//  build is actually on sale the lookup comes back empty, which is indis-
//  tinguishable from "up to date" and equally silent — so this can ship before
//  the store record exists.
//

import Foundation
import os

enum UpdateChecker {

    /// The App Store record. iOS and macOS share one listing, so they share
    /// this identifier.
    private static let appStoreID = "6797135085"

    /// What the store is selling, on the occasions it is ahead of us.
    struct Update: Equatable, Sendable {
        let version: String
        let storeURL: URL
    }

    /// The version this build reports, for the "you have…" half of the prompt.
    static var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// `nil` for every outcome except "something newer is on sale".
    ///
    /// Deliberately never throws and never reports a failure to the caller:
    /// a version check that interrupts someone because a network was flaky is
    /// worse than one that quietly does nothing.
    static func check() async -> Update? {
        guard let installed = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !installed.isEmpty,
              let listing = await lookup() else { return nil }

        // `.numeric` compares run by run rather than character by character, so
        // 1.0.10 sorts above 1.0.9 — which a plain string comparison gets
        // backwards, and gets backwards silently.
        guard listing.version.compare(installed, options: .numeric) == .orderedDescending else {
            EngineLog.client.debug("Update check: \(installed, privacy: .public) is current")
            return nil
        }

        EngineLog.client.notice("Update available: \(listing.version, privacy: .public)")
        return listing
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
        var items = [URLQueryItem(name: "id", value: appStoreID),
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

    private static func parse(_ data: Data) -> Update? {
        struct Payload: Decodable {
            struct Entry: Decodable {
                let version: String
                let trackViewUrl: String
            }
            let results: [Entry]
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let entry = payload.results.first,
              let url = URL(string: entry.trackViewUrl) else { return nil }
        return Update(version: entry.version, storeURL: url)
    }

    /// Ephemeral, so nothing about the lookup is written to disk, and
    /// non-waiting, so it gives up rather than queueing itself against some
    /// later moment when connectivity returns and the user has moved on.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
