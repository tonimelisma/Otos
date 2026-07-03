#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

struct SmokeScrollConfig {
    var appName = "Otos"
    var settleSeconds: TimeInterval = 10
    var cycles = 6
    var pauseSeconds: TimeInterval = 0.25
    var delta = 900
}

enum SmokeScrollError: Error, CustomStringConvertible {
    case usage
    case appNotRunning(String)
    case windowNotFound(String)
    case eventCreationFailed

    var description: String {
        switch self {
        case .usage:
            "usage: smoke-scroll.swift [--app Otos] [--settle 10] [--cycles 6] [--pause 0.25] [--delta 900]"
        case let .appNotRunning(appName):
            "app is not running: \(appName)"
        case let .windowNotFound(appName):
            "on-screen app window not found: \(appName)"
        case .eventCreationFailed:
            "failed to create a scroll-wheel event"
        }
    }
}

func parseConfig(arguments: [String]) throws -> SmokeScrollConfig {
    var config = SmokeScrollConfig()
    var index = 1
    while index < arguments.count {
        let option = arguments[index]
        func nextValue() throws -> String {
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw SmokeScrollError.usage
            }
            index = valueIndex
            return arguments[valueIndex]
        }

        switch option {
        case "--app":
            config.appName = try nextValue()
        case "--settle":
            let rawValue = try nextValue()
            guard let value = TimeInterval(rawValue) else {
                throw SmokeScrollError.usage
            }
            config.settleSeconds = value
        case "--cycles":
            let rawValue = try nextValue()
            guard let value = Int(rawValue), value > 0 else {
                throw SmokeScrollError.usage
            }
            config.cycles = value
        case "--pause":
            let rawValue = try nextValue()
            guard let value = TimeInterval(rawValue) else {
                throw SmokeScrollError.usage
            }
            config.pauseSeconds = value
        case "--delta":
            let rawValue = try nextValue()
            guard let value = Int(rawValue), value > 0 else {
                throw SmokeScrollError.usage
            }
            config.delta = value
        default:
            throw SmokeScrollError.usage
        }
        index += 1
    }
    return config
}

func frontmostWindowBounds(appName: String) -> CGRect? {
    guard let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return nil
    }

    return windows.compactMap { window -> CGRect? in
        guard (window[kCGWindowOwnerName as String] as? String) == appName,
              (window[kCGWindowLayer as String] as? Int) == 0,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds)
        else {
            return nil
        }
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }
    .max { $0.width * $0.height < $1.width * $1.height }
}

func postScroll(delta: Int) throws {
    guard let event = CGEvent(
        scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
        units: .pixel,
        wheelCount: 1,
        wheel1: Int32(delta),
        wheel2: 0,
        wheel3: 0
    ) else {
        throw SmokeScrollError.eventCreationFailed
    }
    event.post(tap: .cghidEventTap)
}

func run() throws {
    let config = try parseConfig(arguments: CommandLine.arguments)
    guard let app = NSWorkspace.shared.runningApplications.first(where: { application in
        application.localizedName == config.appName
    }) else {
        throw SmokeScrollError.appNotRunning(config.appName)
    }
    app.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 0.5)

    guard let bounds = frontmostWindowBounds(appName: config.appName) else {
        throw SmokeScrollError.windowNotFound(config.appName)
    }
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    CGWarpMouseCursorPosition(center)
    CGAssociateMouseAndMouseCursorPosition(boolean_t(1))

    if config.settleSeconds > 0 {
        print("settling for \(config.settleSeconds)s before scrolling")
        Thread.sleep(forTimeInterval: config.settleSeconds)
    }

    print("scrolling down cycles=\(config.cycles) delta=\(config.delta)")
    for _ in 0 ..< config.cycles {
        try postScroll(delta: -config.delta)
        Thread.sleep(forTimeInterval: config.pauseSeconds)
    }

    print("scrolling up cycles=\(config.cycles) delta=\(config.delta)")
    for _ in 0 ..< config.cycles {
        try postScroll(delta: config.delta)
        Thread.sleep(forTimeInterval: config.pauseSeconds)
    }
}

do {
    try run()
} catch SmokeScrollError.usage {
    fputs("smoke-scroll: \(SmokeScrollError.usage.description)\n", stderr)
    exit(2)
} catch let error as SmokeScrollError {
    fputs("smoke-scroll: \(error.description)\n", stderr)
    exit(1)
} catch {
    fputs("smoke-scroll: \(error)\n", stderr)
    exit(1)
}
