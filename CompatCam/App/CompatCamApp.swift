//
//  CompatCamApp.swift
//  CompatCam
//

import SwiftUI

@main
struct CompatCamApp: App {
    var body: some Scene {
        WindowGroup {
            CameraCaptureView()
                .preferredColorScheme(.dark)
        }
    }
}
