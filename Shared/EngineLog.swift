//
//  EngineLog.swift
//  Shared between FaceFusionMac (app) and FaceFusionEngine (XPC service).
//
//  The engine runs out-of-process, so its failures are invisible in the app's
//  console. Routing both sides through one subsystem makes the whole pipeline
//  greppable:
//
//      log stream --predicate 'subsystem == "com.lisenhuang.FaceFusionMac"'
//

import Foundation
import os

public enum EngineLog {
    public static let subsystem = "com.lisenhuang.FaceFusionMac"

    /// Model loading and execution-provider selection.
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    /// Per-frame inference.
    public static let inference = Logger(subsystem: subsystem, category: "inference")
    /// The app side of the XPC link.
    public static let client = Logger(subsystem: subsystem, category: "client")
    /// Downloads and installation.
    public static let models = Logger(subsystem: subsystem, category: "models")
}
