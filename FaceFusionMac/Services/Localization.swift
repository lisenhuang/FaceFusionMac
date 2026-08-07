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
    private let languageKey = "appearance.language"

    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: languageKey) }
    }

    private init() {
        language = AppLanguage(rawValue: defaults.string(forKey: languageKey) ?? "") ?? .system
    }
}
