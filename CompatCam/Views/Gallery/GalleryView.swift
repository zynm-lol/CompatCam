//
//  GalleryView.swift
//  CompatCam
//
//  A lightweight built-in gallery using PhotoKit (public API) to show
//  recently captured photos, with view/share/delete/favorite actions.
//

import Photos
import SwiftUI

@MainActor
final class GalleryViewModel: ObservableObject {
    @Published var assets: [PHAsset] = []
    @Published var thumbnails: [String: UIImage] = [:]

    func load() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = 100

        let result = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        var collected: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in collected.append(asset) }
        assets = collected

        loadThumbnails()
    }

    private func loadThumbnails() {
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isSynchronous = false

        for asset in assets.prefix(60) {
            manager.requestImage(
                for: asset,
                targetSize: CGSize(width: 200, height: 200),
                contentMode: .aspectFill,
                options: options
            ) { [weak self] image, _ in
                guard let self, let image else { return }
                Task { @MainActor in
                    self.thumbnails[asset.localIdentifier] = image
                }
            }
        }
    }

    func toggleFavorite(_ asset: PHAsset) {
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.isFavorite = !asset.isFavorite
        }
    }

    func delete(_ asset: PHAsset) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }
    }
}

struct GalleryView: View {
    @StateObject private var viewModel = GalleryViewModel()
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 4)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(viewModel.assets, id: \.localIdentifier) { asset in
                        thumbnail(for: asset)
                    }
                }
            }
            .navigationTitle("Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await viewModel.load() }
        }
    }

    @ViewBuilder
    private func thumbnail(for asset: PHAsset) -> some View {
        if let image = viewModel.thumbnails[asset.localIdentifier] {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 110, height: 110)
                .clipped()
                .contextMenu {
                    Button(asset.isFavorite ? "Unfavorite" : "Favorite") {
                        viewModel.toggleFavorite(asset)
                    }
                    Button("Delete", role: .destructive) {
                        viewModel.delete(asset)
                    }
                }
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: 110, height: 110)
        }
    }
}
