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
    /// Never wire this to a button. Apple's guidelines require the prompt to
    /// follow a natural, successful moment rather than an affordance the user
    /// went looking for, and a "Rate us" control is exactly the thing they
    /// forbid — quite apart from spending three system-metered requests on
    /// people who tapped it out of curiosity.
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
        requestReview()
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
