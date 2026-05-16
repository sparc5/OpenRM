//
//  ContentView.swift
//  OpenRM
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct ContentView: View {
    @AppStorage("hasAcceptedDisclaimer") private var hasAcceptedDisclaimer = false

    var body: some View {
        if hasAcceptedDisclaimer {
            DashboardView()
                .preferredColorScheme(.dark)
                #if canImport(AppKit)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                }
                #endif
        } else {
            DisclaimerView {
                hasAcceptedDisclaimer = true
            }
        }
    }
}

#Preview {
    ContentView()
}
