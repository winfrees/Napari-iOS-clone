import NapariCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            LayerSidebar(model: model)
                .navigationTitle("Layers")
                .toolbar { sidebarToolbar }
        } detail: {
            VStack(spacing: 0) {
                CanvasView(model: model)
                    .overlay { emptyState }
                DimsSliders(dims: model.viewer.dims)
                StatusBar(model: model)
            }
            .navigationTitle("napari")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { canvasToolbar }
        }
        .fileImporter(
            isPresented: Binding(get: { model.importTarget != nil }, set: { if !$0 { model.importTarget = nil } }),
            allowedContentTypes: model.importTarget?.contentTypes ?? [.tiff],
            allowsMultipleSelection: true
        ) { result in
            let target = model.importTarget ?? .image
            model.importTarget = nil
            switch result {
            case .success(let urls): model.open(urls, as: target)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: Binding(get: { model.exportDocument != nil }, set: { if !$0 { model.exportDocument = nil } }),
            document: model.exportDocument,
            contentType: model.exportDocument?.contentType ?? .tiff,
            defaultFilename: model.exportDocument?.filename
        ) { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
            model.exportDocument = nil
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.viewer.layers.isEmpty {
            ContentUnavailableView {
                Label("No layers", systemImage: "square.3.layers.3d")
            } description: {
                Text("Open a TIFF stack or load sample data.")
            } actions: {
                Button("Open TIFF…") { model.importTarget = .image }
                Button("Load sample blobs") { model.loadSampleBlobs() }
            }
        } else if model.isLoading {
            ProgressView()
        }
    }

    @ToolbarContentBuilder private var sidebarToolbar: some ToolbarContent {
        ToolbarItem {
            Menu {
                Button("Open Image…", systemImage: "photo") { model.importTarget = .image }
                Button("Open Labels…", systemImage: "square.dashed") { model.importTarget = .labels }
                Button("Open Points CSV…", systemImage: "circle.grid.2x2") { model.importTarget = .points }
                Divider()
                Button("Sample: Blobs", systemImage: "circle.hexagongrid") { model.loadSampleBlobs() }
                Divider()
                Button("Export Layer…", systemImage: "square.and.arrow.up") { model.exportSelectedLayer() }
                    .disabled(!model.canExportSelectedLayer)
            } label: {
                Label("File", systemImage: "folder")
            }
        }
        ToolbarItem {
            Menu {
                Button("New Labels Layer", systemImage: "square.dashed") { model.addEmptyLabels() }
                Button("New Points Layer", systemImage: "circle.grid.2x2") { model.addEmptyPoints() }
            } label: {
                Label("New Layer", systemImage: "plus.square.on.square")
            }
            .disabled(model.viewer.layers.isEmpty)
        }
    }

    @ToolbarContentBuilder private var canvasToolbar: some ToolbarContent {
        ToolbarItem {
            let is3D = model.viewer.dims.ndisplay == 3
            Button(is3D ? "Switch to 2D" : "Switch to 3D", systemImage: is3D ? "square" : "cube") {
                model.toggle3D()
            }
            .disabled(model.viewer.dims.ndim < 3)
        }
        ToolbarItem {
            Button("Reset View", systemImage: "house") { model.needsResetView = true }
        }
    }
}

/// Shows the cursor position and the value under it.
struct StatusBar: View {
    let model: AppModel

    var body: some View {
        Text(model.status.isEmpty ? " " : model.status)
            .font(.caption.monospaced())
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
    }
}

/// One slider per non-displayed axis, like napari's dims sliders.
struct DimsSliders: View {
    let dims: Dims

    var body: some View {
        if !dims.sliderAxes.isEmpty {
            VStack(spacing: 4) {
                ForEach(dims.sliderAxes, id: \.self) { axis in
                    HStack {
                        Text(dims.axisLabels[axis])
                            .font(.caption.monospaced())
                            .frame(width: 24)
                        Slider(
                            value: Binding(
                                get: { Double(dims.point[axis]) },
                                set: { dims.setPoint(axis: axis, to: Int($0.rounded())) }
                            ),
                            in: 0 ... Double(dims.range[axis] - 1),
                            step: 1
                        )
                        Text("\(dims.point[axis]) / \(dims.range[axis] - 1)")
                            .font(.caption.monospaced())
                            .frame(minWidth: 70, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}
