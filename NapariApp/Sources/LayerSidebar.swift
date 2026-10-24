import NapariCore
import SwiftUI

/// Controls for the selected layer above the layer list, as in napari's left dock.
struct LayerSidebar: View {
    @Bindable var model: AppModel

    private var viewer: Viewer { model.viewer }

    /// Top layer first, as napari lists them.
    private var displayedLayers: [any Layer] { viewer.layers.reversed() }

    var body: some View {
        List(selection: Bindable(viewer).selectedLayerID) {
            if let layer = viewer.selectedLayer {
                Section("Layer controls") {
                    LayerControls(layer: layer, model: model)
                }
                .selectionDisabled()
            }
            Section("Layers") {
                ForEach(displayedLayers, id: \.id) { layer in
                    LayerRow(props: layer.props, kind: layer is LabelsLayer ? .labels : .image)
                        .tag(layer.id)
                }
                .onMove { source, destination in
                    var ids = displayedLayers.map(\.id)
                    ids.move(fromOffsets: source, toOffset: destination)
                    viewer.reorderLayers(ids.reversed())
                }
                .onDelete { offsets in
                    for id in offsets.map({ displayedLayers[$0].id }) {
                        viewer.removeLayer(id: id)
                    }
                }
            }
        }
    }
}

struct LayerRow: View {
    enum Kind {
        case image
        case labels
    }

    @Bindable var props: LayerProperties
    let kind: Kind

    var body: some View {
        HStack {
            Button {
                props.visible.toggle()
            } label: {
                Image(systemName: props.visible ? "eye" : "eye.slash")
                    .foregroundStyle(props.visible ? .primary : .secondary)
            }
            .buttonStyle(.borderless)
            Image(systemName: kind == .labels ? "square.dashed.inset.filled" : "photo")
                .foregroundStyle(.secondary)
            TextField("Name", text: $props.name)
        }
    }
}

struct LayerControls: View {
    let layer: any Layer
    let model: AppModel

    var body: some View {
        CommonControls(props: layer.props)
        if let image = layer as? ImageLayer {
            ImageControls(layer: image)
        } else if let labels = layer as? LabelsLayer {
            LabelsControls(layer: labels, model: model)
        }
    }
}

struct CommonControls: View {
    @Bindable var props: LayerProperties

    var body: some View {
        LabeledContent("Opacity") {
            Slider(value: $props.opacity, in: 0 ... 1)
        }
        Picker("Blending", selection: $props.blending) {
            ForEach(Blending.allCases) { Text($0.rawValue).tag($0) }
        }
    }
}

struct ImageControls: View {
    @Bindable var layer: ImageLayer

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Contrast limits")
                Spacer()
                Text("\(format(layer.contrastLimits.lowerBound)) – \(format(layer.contrastLimits.upperBound))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Button("Reset", action: layer.resetContrastLimits)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            Slider(value: lowerLimit, in: layer.dataRange)
            Slider(value: upperLimit, in: layer.dataRange)
        }
        LabeledContent("Gamma") {
            Slider(value: $layer.gamma, in: 0.2 ... 2)
        }
        Picker("Colormap", selection: $layer.colormap) {
            ForEach(Colormap.builtins) { colormap in
                Text(colormap.name).tag(colormap)
            }
        }
        ColormapBar(colormap: layer.colormap)
        Picker("Interpolation", selection: $layer.interpolation) {
            ForEach(Interpolation.allCases) { Text($0.rawValue).tag($0) }
        }
    }

    private var minimumGap: Float { (layer.dataRange.upperBound - layer.dataRange.lowerBound) / 1000 }

    private var lowerLimit: Binding<Float> {
        Binding(
            get: { layer.contrastLimits.lowerBound },
            set: { layer.contrastLimits = min($0, layer.contrastLimits.upperBound - minimumGap) ... layer.contrastLimits.upperBound }
        )
    }

    private var upperLimit: Binding<Float> {
        Binding(
            get: { layer.contrastLimits.upperBound },
            set: { layer.contrastLimits = layer.contrastLimits.lowerBound ... max($0, layer.contrastLimits.lowerBound + minimumGap) }
        )
    }

    private func format(_ value: Float) -> String {
        String(format: "%.4g", value)
    }
}

struct ColormapBar: View {
    let colormap: Colormap

    var body: some View {
        LinearGradient(
            stops: colormap.controls.map {
                Gradient.Stop(color: Color(red: Double($0.color.r), green: Double($0.color.g), blue: Double($0.color.b)),
                              location: CGFloat($0.position))
            },
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct LabelsControls: View {
    @Bindable var layer: LabelsLayer
    @Bindable var model: AppModel

    var body: some View {
        Picker("Mode", selection: $layer.mode) {
            ForEach(LabelsMode.allCases) { mode in
                Image(systemName: Self.symbol(for: mode))
                    .accessibilityLabel(mode.rawValue)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        LabeledContent("Label") {
            HStack {
                let color = LabelsLayer.color(for: layer.selectedLabel)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(red: Double(color.r), green: Double(color.g), blue: Double(color.b),
                                opacity: Double(color.a)))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary))
                    .frame(width: 20, height: 20)
                Stepper("\(layer.selectedLabel)", value: $layer.selectedLabel, in: 0 ... UInt32.max - 1)
                    .monospacedDigit()
            }
        }
        Button("New label", systemImage: "plus.circle") {
            layer.selectedLabel = layer.largestLabel + 1
        }
        LabeledContent("Brush size") {
            HStack {
                Slider(value: $layer.brushSize, in: 1 ... 100)
                Text("\(Int(layer.brushSize))")
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
        }
        Toggle("Contiguous fill", isOn: $layer.contiguousFill)
        Toggle("Paint with Apple Pencil only", isOn: $model.pencilOnly)
        HStack {
            Button("Undo", systemImage: "arrow.uturn.backward", action: layer.undo)
                .disabled(!layer.canUndo)
            Spacer()
            Button("Redo", systemImage: "arrow.uturn.forward", action: layer.redo)
                .disabled(!layer.canRedo)
        }
        .buttonStyle(.borderless)
    }

    static func symbol(for mode: LabelsMode) -> String {
        switch mode {
        case .panZoom: return "arrow.up.and.down.and.arrow.left.and.right"
        case .paint: return "paintbrush.pointed"
        case .erase: return "eraser"
        case .fill: return "drop"
        case .pick: return "eyedropper"
        }
    }
}
