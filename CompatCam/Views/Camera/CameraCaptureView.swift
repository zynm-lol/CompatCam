//
//  CameraCaptureView.swift
//  CompatCam
//
//  The primary screen: live preview + top/bottom controls, matching the
//  "Professional minimalist design" requirement. Handles the startup
//  search state and interruption/recovery states gracefully instead of
//  ever showing a crash or a frozen screen.
//

import AVFoundation
import SwiftUI

struct CameraCaptureView: View {
    @StateObject private var viewModel = CameraViewModel()
    @ObservedObject private var diagnosticsPublisher = DiagnosticsLogger.shared.publisher

    @State private var showCompatibilityMenu = false
    @State private var showDiagnostics = false
    @State private var showManualControls = false
    @State private var showGallery = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(session: viewModel.manager.session) { point in
                viewModel.focus(at: point)
            }
            .ignoresSafeArea()

            overlayLayer

            VStack {
                topBar
                modeSwitcher
                Spacer()
                if viewModel.isHistogramVisible {
                    HistogramView(bins: viewModel.frameAnalysis.histogramBins)
                        .frame(height: 60)
                        .padding(.horizontal)
                }
                filterStrip
                bottomBar
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)

            if viewModel.isCountingDown {
                countdownOverlay
            } else if viewModel.isStartingUp {
                startupOverlay
            } else if viewModel.manager.published.sessionState == .recovering {
                recoveryBanner
            } else if let error = viewModel.startupErrorMessage {
                errorOverlay(message: error)
            }
        }
        .statusBarHidden()
        .task { await viewModel.start() }
        .sheet(isPresented: $showCompatibilityMenu) {
            CompatibilityMenuView(
                currentMode: viewModel.compatibilityMode,
                onSelect: { mode in
                    showCompatibilityMenu = false
                    Task { await viewModel.restart(mode: mode) }
                }
            )
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(engine: viewModel.engine, manager: viewModel.manager)
        }
        .sheet(isPresented: $showManualControls) {
            ManualControlsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showGallery) {
            GalleryView()
        }
    }

    // MARK: - Live analysis overlays (focus peaking / zebra)

    @ViewBuilder
    private var overlayLayer: some View {
        if viewModel.isFocusPeakingVisible, let cgImage = viewModel.frameAnalysis.focusPeakingOverlay {
            Image(decorative: cgImage, scale: 1.0)
                .resizable()
                .scaledToFill()
                .blendMode(.screen)
                .opacity(0.9)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        if viewModel.isZebraVisible, let cgImage = viewModel.frameAnalysis.zebraOverlay {
            Image(decorative: cgImage, scale: 1.0)
                .resizable()
                .scaledToFill()
                .blendMode(.difference)
                .opacity(0.6)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 20) {
            iconButton(systemName: viewModel.manager.published.isTorchOn ? "bolt.fill" : "bolt.slash") {
                viewModel.toggleTorch()
            }
            iconButton(systemName: viewModel.timerSeconds > 0 ? "timer" : "timer") {
                viewModel.timerSeconds = viewModel.timerSeconds == 0 ? 3 : (viewModel.timerSeconds == 3 ? 10 : 0)
            }
            .overlay(alignment: .topTrailing) {
                if viewModel.timerSeconds > 0 {
                    Text("\(viewModel.timerSeconds)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(3)
                        .background(Circle().fill(.yellow))
                        .foregroundStyle(.black)
                        .offset(x: 4, y: -4)
                }
            }
            iconButton(systemName: "waveform.path.ecg.rectangle") {
                viewModel.isHistogramVisible.toggle()
            }
            .opacity(viewModel.isHistogramVisible ? 1.0 : 0.55)

            Menu {
                Toggle("Focus Peaking", isOn: $viewModel.isFocusPeakingVisible)
                Toggle("Zebra Stripes", isOn: $viewModel.isZebraVisible)
            } label: {
                Image(systemName: "eye")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.black.opacity(0.3)))
            }
            .opacity((viewModel.isFocusPeakingVisible || viewModel.isZebraVisible) ? 1.0 : 0.55)

            Spacer()

            iconButton(systemName: "slider.horizontal.3") { showManualControls = true }
            iconButton(systemName: "checkerboard.rectangle") { showCompatibilityMenu = true }
            iconButton(systemName: "waveform.path.ecg") { showDiagnostics = true }
        }
        .foregroundStyle(.white)
    }

    // MARK: - Mode switcher (Photo / Video / Manual)

    private var modeSwitcher: some View {
        Picker("Mode", selection: Binding(
            get: { viewModel.captureMode },
            set: { newMode in Task { await viewModel.setCaptureMode(newMode) } }
        )) {
            ForEach(CaptureMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
        .padding(.top, 6)
    }

    // MARK: - Filter strip

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(LiveFilter.allCases) { filter in
                    Text(filter.rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(filter == viewModel.selectedFilter ? Color.white : Color.white.opacity(0.15))
                        )
                        .foregroundStyle(filter == viewModel.selectedFilter ? .black : .white)
                        .onTapGesture { viewModel.selectedFilter = filter }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            galleryButton
            Spacer()
            captureButton
            Spacer()
            iconButton(systemName: "arrow.triangle.2.circlepath.camera") {
                let next: AVCaptureDevice.Position = viewModel.cameraPosition == .back ? .front : .back
                Task { await viewModel.restart(position: next) }
            }
        }
    }

    private var galleryButton: some View {
        Button { showGallery = true } label: {
            Group {
                if let image = viewModel.lastCaptureThumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 1))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.15))
                        .frame(width: 46, height: 46)
                }
            }
        }
    }

    @ViewBuilder
    private var captureButton: some View {
        switch viewModel.captureMode {
        case .photo, .manual:
            Button {
                Task { await viewModel.capturePhoto() }
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                    Circle().fill(.white).frame(width: 60, height: 60)
                        .opacity(viewModel.isCapturing || viewModel.isBurstCapturing ? 0.4 : 1.0)
                }
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    Task { await viewModel.captureBurst() }
                }
            )
            .disabled(viewModel.isCapturing || viewModel.isBurstCapturing || viewModel.isStartingUp)
            .sensoryFeedback(.impact, trigger: viewModel.isCapturing)

        case .video:
            Button {
                Task { await viewModel.toggleRecording() }
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                    if viewModel.manager.published.isRecordingVideo {
                        RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                    } else {
                        Circle().fill(.red).frame(width: 60, height: 60)
                    }
                }
            }
            .overlay(alignment: .top) {
                if viewModel.manager.published.isRecordingVideo {
                    Text(elapsedString)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                        .padding(.top, -28)
                }
            }
            .disabled(viewModel.isStartingUp)
            .sensoryFeedback(.impact, trigger: viewModel.manager.published.isRecordingVideo)
        }
    }

    private var elapsedString: String {
        let seconds = viewModel.manager.published.recordingElapsedSeconds
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.black.opacity(0.3)))
        }
    }

    // MARK: - Overlays

    private var startupOverlay: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(.white)
            Text("Finding a compatible camera configuration…")
                .foregroundStyle(.white)
                .font(.subheadline)
            if !viewModel.engine.attempts.isEmpty {
                Text("Tried \(viewModel.engine.attempts.count) configuration(s)")
                    .foregroundStyle(.white.opacity(0.6))
                    .font(.caption)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var recoveryBanner: some View {
        VStack {
            Spacer()
            HStack {
                ProgressView().tint(.white)
                Text("Recovering camera session…")
                    .foregroundStyle(.white)
            }
            .padding()
            .background(.black.opacity(0.6), in: Capsule())
            .padding(.bottom, 140)
        }
    }

    private var countdownOverlay: some View {
        Text("\(viewModel.countdownRemaining)")
            .font(.system(size: 96, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(40)
            .background(.black.opacity(0.35), in: Circle())
    }

    private func errorOverlay(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("Camera Unavailable")
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Maximum Compatibility") {
                Task { await viewModel.restart(mode: .maximumCompatibility) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(32)
    }
}

#Preview {
    CameraCaptureView()
}
