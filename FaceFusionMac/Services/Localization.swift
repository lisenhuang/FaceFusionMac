//
//  Localization.swift
//  FaceFusionMac
//
//  The Mac interface follows the system by default, but the user can choose
//  the same supported languages as the iOS app from Morphiqo's Settings.
//

import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case korean = "ko"
    case japanese = "ja"

    var id: String { rawValue }

    /// Endonyms stay recognizable even when the current interface language is
    /// not the language the user intended to choose.
    var label: String {
        switch self {
        case .system:            return "System"
        case .english:           return "English"
        case .simplifiedChinese: return "简体中文"
        case .korean:            return "한국어"
        case .japanese:          return "日本語"
        }
    }

    var locale: Locale {
        localeIdentifier.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    private var localeIdentifier: String? {
        self == .system ? nil : rawValue
    }
}

@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let language = "appearance.language"
        static let successfulSaveCount = "review.successfulSaveCount"
        static let lastPromptedVersion = "review.lastPromptedVersion"
    }

    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }

    // MARK: - Review prompt

    /// How many exports have actually written a file, for all time. See
    /// `ReviewPrompt`, which is the only thing that reads it.
    var successfulSaveCount: Int {
        didSet { defaults.set(successfulSaveCount, forKey: Key.successfulSaveCount) }
    }

    /// The marketing version that last asked for a review, or `nil` if none
    /// has. Deliberately not a `Bool`: "have we asked?" would be permanent, and
    /// the point is to ask again — at most once — after the app has changed.
    var lastPromptedVersion: String? {
        didSet {
            if let lastPromptedVersion {
                defaults.set(lastPromptedVersion, forKey: Key.lastPromptedVersion)
            } else {
                defaults.removeObject(forKey: Key.lastPromptedVersion)
            }
        }
    }

    private init() {
        // Registered rather than written, so a key nobody has touched stays
        // absent from the store and still reads as the value intended here.
        // This is what an install upgrading from a build that predates the
        // review prompt lands on: zero saves so far, never prompted — rather
        // than whatever `integer(forKey:)` invents for a missing key.
        defaults.register(defaults: [
            Key.language: AppLanguage.system.rawValue,
            Key.successfulSaveCount: 0
        ])
        // `lastPromptedVersion` has no registered default on purpose: absent
        // *is* the meaning, and a placeholder string would have to be compared
        // against every real version forever.

        language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .system
        successfulSaveCount = defaults.integer(forKey: Key.successfulSaveCount)
        lastPromptedVersion = defaults.string(forKey: Key.lastPromptedVersion)
    }
}
