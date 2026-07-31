//
//  main.swift
//  FaceFusionEngine
//
//  Entry point for the embedded XPC service. launchd starts this on demand
//  when the app opens a connection, and reaps it when the app goes away.
//

import Foundation

let delegate = EngineServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate

// Does not return: hands control to the XPC runloop.
listener.resume()
