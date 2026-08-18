//
//  ReviewPrompt.swift
//  FaceFusionMac
//
//  Decides whether this is a moment worth asking someone to rate Morphiqo.
//
//  The rules live here and only here. There is one call site today, but the
//  policy below is the kind that gets copied to the second one and then only
//  half-updated, so the view is left with a single question to ask and no say
//  in the answer.
//
//  Why it is this conservative: the system allows three prompts per user per
//  365 days and decides on its own whether any given request draws anything at
//  all. A request is spent whether or not the user ever sees it, so asking on
//  every export quietly burns the year's allowance on people who are still
//  working out what the app does — and leaves nothing for the person who has
//  been exporting happily for months. Rarity is the whole point.
//
//  Nothing here goes to the App Store. `requestReview` presents Apple's own
//  sheet inside this process; the user rates the app and carries on with the
//  export they just finished, without the app ever handing them off.
//

import SwiftUI
import StoreKit
import AppKit

@MainActor
enum ReviewPrompt {

    /// The first two exports do not count. A first-time user has not formed an
    /// opinion yet, and asking for one is how you get a two-star review of a
    /// feature they had not found.
    static let minimumSuccessfulSaves = 3

    /// Long enough for "Export complete" to land and be read first. The prompt
    /// arriving on the same frame as the success bar reads as a reaction to the
    /// click rather than to the result.
    private static let settleDelay = Duration.seconds(1.5)

    /// Counts an export that actually produced a file.
    ///
    /// Called only from the success branch: a cancel, a failure, or an export
    /// the user backed out of at the save panel is not a moment anyone enjoyed,
    /// and counting it would move everybody towards a prompt they did not earn.
    static func recordSuccessfulSave() {
        Preferences.shared.successfulSaveCount += 1
    }

    /// Whether the policy permits asking right now.
    private static var isEarned: Bool {
        // `--benchmark`, `--profile` and `--selftest` drive the app with no
        // window to put a sheet in front of, and a scripted run that stops for
        // an unanswerable prompt is a hang, not a test failure.
        guard !Benchmark.isRequested, !Benchmark.isProfileRequested, !SelfTest.isRequested else {
            return false
        }
        guard let currentVersion else { return false }
        guard Preferences.shared.successfulSaveCount >= minimumSuccessfulSaves else { return false }
        // At most once per version. Somebody who declined has answered for this
        // build; the next one is allowed to ask again because it is a different
        // app to have an opinion about.
        return Preferences.shared.lastPromptedVersion != currentVersion
    }

    /// Asks, if the moment has earned it. Does nothing otherwise, which is the
    /// common case.
    ///
    /// Not for a button. The guidelines are about *unprompted* asks: one has to
    /// follow a natural, successful moment rather than arrive because the app
    /// felt like asking. Settings has a Rate control and it goes through
    /// `rate(_:)` instead, which answers to a different requirement — a button
    /// the user pressed must never do nothing.
    static func requestIfEarned(_ requestReview: RequestReviewAction) async {
        guard isEarned else { return }

        // A cancelled sleep means the finished bar was dismissed or the export
        // was replaced while we waited, so the moment is gone. Returning rather
        // than asking late also leaves the request unspent.
        do {
            try await Task.sleep(for: settleDelay)
        } catch {
            return
        }

        // The finished bar's own buttons are the likely thing to happen during
        // that wait, and the prominent one is "Open" — it hands the file to a
        // player, and "Show in Finder" hands it to Finder. Neither touches
        // `phase`, so neither cancels the sleep above, and both leave Morphiqo
        // behind somebody else's window. Asking from there puts the sheet where
        // nobody is looking while still spending the request and marking the
        // version as asked, which is the one outcome this whole file exists to
        // avoid. Not frontmost means the moment belonged to the file, not to us.
        guard NSApplication.shared.isActive else { return }

        // Recorded before the call, not after. `requestReview` returns as soon
        // as the system has taken the request and reports nothing about what it
        // did with it, so "we asked" is the only fact there is to remember —
        // and it has to be remembered even if the system showed nothing, since
        // the allowance was spent either way.
        Preferences.shared.lastPromptedVersion = currentVersion
        spendAllowance()
        requestReview()
    }

    // MARK: - The Settings button

    /// How many requests the system grants per person per year.
    ///
    /// Apple's number, not ours, and it is the reason this file is careful.
    private static let allowancePerYear = 3

    /// Where a review can always be left, when the sheet cannot be shown.
    private static let writeReviewURL = URL(
        string: "https://apps.apple.com/app/id6797135085?action=write-review")!

    /// Whether a request now stands any chance of being shown.
    ///
    /// A guess, and unavoidably so: the system keeps the real count and never
    /// discloses it. Ours is drawn from the only calls that can affect it —
    /// this app's — and it is wrong in one direction only. An install upgraded
    /// from a build that predates this record starts with an empty history and
    /// may believe it has an ask it has already spent; the cost is one press
    /// that shows nothing, after which the record is accurate.
    private static var hasAllowanceLeft: Bool {
        let cutoff = Date().addingTimeInterval(-365 * 24 * 60 * 60).timeIntervalSince1970
        let recent = Preferences.shared.reviewRequestDates.filter { $0 > cutoff }
        return recent.count < allowancePerYear
    }

    /// Records a request against the year's allowance, and forgets the ones
    /// that have aged out so the list cannot grow without bound.
    private static func spendAllowance() {
        let cutoff = Date().addingTimeInterval(-365 * 24 * 60 * 60).timeIntervalSince1970
        var dates = Preferences.shared.reviewRequestDates.filter { $0 > cutoff }
        dates.append(Date().timeIntervalSince1970)
        Preferences.shared.reviewRequestDates = dates
    }

    /// The Rate button in Settings.
    ///
    /// Returns `nil` when it asked in place, or a URL the caller should open
    /// when it could not. Both outcomes leave a review possible, which is the
    /// requirement a button carries and an automatic prompt does not: a prompt
    /// that stays silent has simply chosen not to interrupt, while a button
    /// that does nothing is broken.
    ///
    /// Deliberately not gated on `successfulSaveCount` or on the once-per-version
    /// rule. Those exist to stop the app asking people who have not been asked
    /// to be asked. Someone who went into Settings and pressed this has asked.
    static func rate(_ request: RequestReviewAction) -> URL? {
        guard hasAllowanceLeft else { return writeReviewURL }
        spendAllowance()
        request()
        return nil
    }


    /// The marketing version, which is what "once per version" is keyed on.
    ///
    /// `nil` only if the bundle is malformed. In that case `isEarned` refuses:
    /// with nothing to remember having asked against, every export would ask
    /// again.
    private static var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
