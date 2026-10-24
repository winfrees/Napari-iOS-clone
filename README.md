# napari for iPad

A native iPad viewer for multi-dimensional images, modelled on [napari](https://napari.org).
It is written in Swift, SwiftUI and Metal rather than ported: napari's Qt, vispy/OpenGL and
plugin stack don't run on iOS. The goal is napari's core ideas (layers, dims sliders,
contrast and colormaps, label painting) with an interface built for touch and Apple Pencil.

## Status

Early scaffold. Working so far:

- **Layers:** image and labels layers, with visibility, opacity, blending (translucent,
  additive, opaque), renaming, reordering and deleting.
- **Images:** contrast limits, gamma, colormaps (gray, viridis, magma, inferno and
  single-color ramps) and nearest/linear interpolation, all applied on the GPU.
- **N-D data:** one slider per non-displayed axis. Layers with fewer dimensions are
  right-aligned, as in napari.
- **Labels:** paint, erase, flood fill and pick with Apple Pencil or finger, with undo and
  redo. Double-tap the Pencil to switch between paint and erase. Turn on "Paint with Apple
  Pencil only" to keep fingers for panning.
- **Points:** add points with a tap or the Pencil, select and drag them, delete the
  selection; size and colors are adjustable. Import and export use napari's points CSV
  format (`index,axis-0,axis-1,…`), so files move both ways.
- **Shapes:** rectangles, ellipses and lines by dragging, polygons by tapping vertices,
  freehand paths with the Pencil; select, drag and delete shapes; edge width and colors are
  adjustable. Import and export use napari's shapes CSV format
  (`index,shape-type,vertex-index,axis-0,…`).
- **3D:** volumes ray-cast on the GPU with maximum (MIP), minimum or average intensity
  projection, using the layer's colormap and contrast. Drag to rotate, two fingers to pan,
  pinch to zoom. Extra axes such as time keep their sliders.
- **Navigation:** one-finger pan, pinch zoom, trackpad scroll zoom, and a status bar
  showing the coordinates and value under the pointer.
- **Files:** grayscale TIFF stacks (uncompressed or PackBits; 8/16/32-bit integer or float;
  ImageJ hyperstack and tifffile shape metadata). Labels export as TIFFs that
  `tifffile`/napari read back with the original shape.
- **OME-Zarr:** open a `.zarr` folder from Files or an HTTP(S) URL (such as the IDR's
  public images). Supports Zarr v2 and unsharded v3, OME-NGFF 0.1–0.5 and bioformats2raw
  layouts. Chunks may be uncompressed or zlib, gzip, zstd, LZ4 or Blosc (LZ4, zlib, zstd)
  compressed. The highest-resolution pyramid level under 64 million voxels is loaded, and
  channels become additive layers using the file's colors and contrast windows.
- **Sample data:** a synthetic blobs volume.

Not yet: labels, points and shapes in 3D, voxel scale (anisotropic z), editing shape vertices,
lazy (chunk-on-demand) and sharded Zarr, Blosc's blosclz codec, compressed or RGB TIFFs,
layer scale/translate, multiscale or tiled display of very large planes, and Python scripting.

## Layout

| Path | What |
| --- | --- |
| `NapariCore/` | Swift package with the model: `NDArray`, `Viewer`, `Dims`, `Camera`, `ImageLayer`, `LabelsLayer`, `PointsLayer`, `ShapesLayer` (with triangulation and hit testing), `Colormap`, TIFF reading and writing, Zarr/OME-Zarr reading. No UI code, unit-tested with `swift test`. |
| `NapariApp/Sources/` | The iPad app: SwiftUI views, the Metal renderer and shaders, and canvas input handling. |
| `project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec for the Xcode project. The generated `.xcodeproj` is not committed. |
| `.github/workflows/ci.yml` | Runs the core tests and builds the app for the iOS Simulator on macOS. |

How it maps to napari:

| napari | here |
| --- | --- |
| `napari.Viewer` | `Viewer` (layers, `dims`, `camera`) |
| `viewer.dims` | `Dims`; `DimsSliders` view |
| `Image` layer | `ImageLayer`; `image_fragment` shader |
| `Labels` layer | `LabelsLayer`; `labels_fragment` shader |
| `Points` layer | `PointsLayer`; instanced `points_vertex`/`points_fragment` shaders |
| `Shapes` layer | `ShapesLayer`; triangle meshes built per frame, `shapes_vertex`/`shapes_fragment` |
| `add_image(..., channel_axis=)` | `Viewer.addImageChannels(_:channelAxis:)` |
| vispy canvas | `CanvasMTKView` + `Renderer` (Metal) |
| layer list and layer controls | `LayerSidebar` |

## Building

Requires Xcode 16 or later on a Mac. The app targets iPadOS 17.

```sh
brew install xcodegen
xcodegen generate
open Napari.xcodeproj
```

Pick an iPad simulator or device and run. To run on a device, choose your team under
Signing & Capabilities.

Core tests run without Xcode:

```sh
cd NapariCore && swift test
```

## Design notes

- **Data** is stored as `NDArray<Float>` for images and `NDArray<UInt32>` for labels, in
  row-major order. The last two axes are always the displayed plane, so each slice is a
  contiguous run of memory that is uploaded to the GPU as-is.
- **3D rendering** uploads each volume as a 16-bit normalised 3D texture (filterable on
  every iOS GPU) and casts one orthographic ray per pixel through a full-screen quad,
  about one sample per voxel.
- **Rendering** draws one quad per visible layer, bottom to top. Each layer's current plane
  lives in a texture that is re-uploaded only when the slice or the data changes. Colormaps
  are 256-entry lookup textures. Shaders output premultiplied alpha, and each blending mode
  is its own pipeline state.
- **Label colors** come from a golden-ratio hue sequence. The same formula appears in Swift
  (`LabelsLayer.color(for:)`) and in Metal (`labelColor`), so the sidebar swatch matches the
  canvas.
- **Observation:** the model classes use Swift's `@Observable`. Pixel edits go straight to
  the storage array, and a single `dataVersion` counter is bumped per change, rather than
  notifying observers for every pixel.
