//
//  ContentView.swift
//  OpenRM
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct ContentView: View {
    var body: some View {
        DashboardView()
            .preferredColorScheme(.dark)
            #if canImport(AppKit)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                // Clean exit: nothing to do here — just let the app die.
                // The notification unblocks any hanging RunLoop.
            }
            #endif
    }
}

#Preview {
    ContentView()
}
