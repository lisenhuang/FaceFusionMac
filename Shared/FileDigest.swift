//
//  FileDigest.swift
//  Shared between FaceFusionMac (app) and FaceFusionEngine (XPC service).
//
//  One streaming SHA-256, because both processes have to be able to ask the
//  same question of the same file and get the same answer.
//
//  The app asks it on the way in: a download is verified against the manifest
//  before it is installed, and the adoption pass hashes a legacy file before it
//  will rename it. The engine asks it on the way out, once — after preparation
//  has already failed twice — to find out whether a model file that was
//  verified when it arrived is still the bytes it was. Nothing hashes on a
//  healthy launch; re-reading 900 MB to learn what the file name already says
//  is exactly the startup cost the content-addressed naming exists to avoid.
//

import Foundation
import CryptoKit

public nonisolated enum FileDigest {

    /// Lowercase hex SHA-256 of a file, read in 4 MB chunks so a 300 MB model
    /// never lands in memory whole.
    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 4 << 20)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
