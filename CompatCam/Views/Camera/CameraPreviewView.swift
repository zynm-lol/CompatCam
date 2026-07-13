//
//  CameraPreviewView.swift
//  CompatCam
//
//  SwiftUI has no native AVCaptureVideoPreviewLayer wrapper, so this is
//  the one small, justified use of UIKit interop mentioned in the spec
//  ("No UIKit unless absolutely necessary").
//

import AVFoundation
import SwiftUI
import UIKit

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var onTap: ((CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tapGesture)
        context.coordinator.view = view
        context.coordinator.onTap = onTap

        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.previewLayer.session = session
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var view: PreviewUIView?
        var onTap: ((CGPoint) -> Void)?

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let location = gesture.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: location)
            onTap?(devicePoint)
        }
    }
}
