//
//  RecentLocations.swift
//  FaceFusionMac
//
//  Remembers where the user last picked a face, a video, and an export
//  destination — one folder each, kept apart.
//
//  AppKit already restores "the last folder you used", but it keeps a single
//  value for the whole app, so choosing a video would drag the face picker
//  along with it. In practice these are three different places: portraits live
//  with your photos, footage lives with your footage, and finished renders go
//  somewhere else again.
//
//  Only the folder path is stored, and this process never opens it. The panel
//  is hosted out of process by Powerbox, which is what grants access to
//  whatever the user picks — so `directoryURL` is a hint the panel can act on
//  even for a folder the sandbox would not let this process read itself. That
//  also means a stale path is harmless: the panel just opens elsewhere.
//

import Foundation

struct RecentLocations {

    /// One remembered folder per kind of pick.
    enum Slot: String, CaseIterable {
        case face = "recentDirectory.face"
        case target = "recentDirectory.target"
        case export = "recentDirectory.export"
    }

    static let shared = RecentLocations()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The folder to open a panel in, or `nil` to let AppKit choose.
    func directory(for slot: Slot) -> URL? {
        guard let path = defaults.string(forKey: slot.rawValue), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Records the folder holding `url`. Takes the file the user chose rather
    /// than the panel's directory, so a drag from the Finder updates the
    /// matching picker too.
    func remember(_ url: URL, for slot: Slot) {
        defaults.set(url.deletingLastPathComponent().path, forKey: slot.rawValue)
    }

    func forgetAll() {
        for slot in Slot.allCases { defaults.removeObject(forKey: slot.rawValue) }
    }
}
