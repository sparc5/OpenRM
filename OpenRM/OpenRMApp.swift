//
//  OpenRMApp.swift
//  OpenRM
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@main
struct OpenRMApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #elseif canImport(AppKit)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

#if canImport(UIKit)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Register the BGTask handler EXACTLY once at launch. iOS
        // requires `BGTaskScheduler.register` to happen here — calling
        // it later throws. Registration is idempotent if the task
        // identifier matches the Info.plist's
        // BGTaskSchedulerPermittedIdentifiers entry.
        Task { @MainActor in
            BackgroundSync.shared.registerTasks()
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Queue the next background refresh whenever we're going
        // dark. iOS will fire it some time after earliestBeginDate,
        // balancing against battery + device-usage heuristics.
        Task { @MainActor in
            BackgroundSync.shared.scheduleNextRun()
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Catalyst: clean exit
    }
}
#elseif canImport(AppKit)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true  // Quit when the window closes instead of lingering
    }
}
#endif
