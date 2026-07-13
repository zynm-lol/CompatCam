//
//  HistogramView.swift
//  CompatCam
//
//  Renders the live luminance histogram computed by FrameAnalysisCoordinator
//  as a simple bar chart, matching the "Live Histogram" requirement.
//

import SwiftUI

struct HistogramView: View {
    let bins: [Float]

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(bins.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.85))
                        .frame(height: max(2, CGFloat(value) * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .padding(8)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    HistogramView(bins: (0..<64).map { _ in Float.random(in: 0...1) })
        .frame(height: 60)
        .padding()
        .background(Color.black)
}
