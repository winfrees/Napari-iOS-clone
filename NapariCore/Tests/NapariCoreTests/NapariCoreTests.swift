import XCTest
@testable import NapariCore

final class NDArrayTests: XCTestCase {
    func testStridesAndPlanes() {
        let array = NDArray(shape: [2, 3, 4], storage: (0 ..< 24).map(Float.init))
        XCTAssertEqual(array.strides, [12, 4, 1])
        XCTAssertEqual(array[[1, 2, 3]], 23)
        XCTAssertEqual(array.leadingShape, [2])
        XCTAssertEqual(Array(array.plane(at: [1])), (12 ..< 24).map(Float.init))
        XCTAssertEqual(array.finiteRange(), 0 ... 23)
    }
}

final class DimsTests: XCTestCase {
    func testLayersAreRightAligned() {
        let viewer = Viewer()
        viewer.addImage(NDArray(shape: [5, 3, 8, 8], repeating: 0))
        let image2D = viewer.addImage(NDArray(shape: [8, 8], repeating: 0))
        let volume = viewer.addImage(NDArray(shape: [3, 8, 8], repeating: 0))

        XCTAssertEqual(viewer.dims.ndim, 4)
        XCTAssertEqual(viewer.dims.range, [5, 3, 8, 8])
        XCTAssertEqual(viewer.dims.sliderAxes, [0, 1])

        viewer.dims.setPoint(axis: 0, to: 4)
        viewer.dims.setPoint(axis: 1, to: 99) // clamped
        XCTAssertEqual(viewer.dims.point[1], 2)
        XCTAssertEqual(viewer.dims.planeIndices(forLayerShape: volume.shape), [2])
        XCTAssertEqual(viewer.dims.planeIndices(forLayerShape: image2D.shape), [])
    }

    func testRemovingLayersShrinksDims() {
        let viewer = Viewer()
        let volume = viewer.addImage(NDArray(shape: [4, 8, 8], repeating: 0))
        viewer.addImage(NDArray(shape: [8, 8], repeating: 0))
        viewer.removeLayer(id: volume.id)
        XCTAssertEqual(viewer.dims.ndim, 2)
        XCTAssertEqual(viewer.dims.sliderAxes, [])
    }

    func testUniqueNamesAndReorder() {
        let viewer = Viewer()
        let a = viewer.addImage(NDArray(shape: [2, 2], repeating: 0), name: "cells")
        let b = viewer.addImage(NDArray(shape: [2, 2], repeating: 0), name: "cells")
        XCTAssertEqual(b.name, "cells [1]")
        viewer.reorderLayers([b.id, a.id])
        XCTAssertEqual(viewer.layers.map(\.id), [b.id, a.id])
    }

    func testChannelSplit() {
        let viewer = Viewer()
        // (z=2, c=3, y=2, x=2), value encodes z*100 + c*10.
        var storage: [Float] = []
        for z in 0 ..< 2 { for c in 0 ..< 3 { storage += Array(repeating: Float(z * 100 + c * 10), count: 4) } }
        let layers = viewer.addImageChannels(NDArray(shape: [2, 3, 2, 2], storage: storage), channelAxis: 1)
        XCTAssertEqual(layers.count, 3)
        XCTAssertEqual(layers[2].shape, [2, 2, 2])
        XCTAssertEqual(layers[2].data[[1, 0, 0]], 120)
        XCTAssertEqual(layers[1].props.blending, .additive)
    }
}

final class CameraTests: XCTestCase {
    func testZoomKeepsAnchorFixed() {
        let camera = Camera()
        let view = SIMD2<Double>(800, 600)
        camera.fit(width: 100, height: 50, viewSize: view)
        XCTAssertEqual(camera.center, SIMD2(50, 25))
        let anchor = SIMD2<Double>(123, 456)
        let before = camera.dataPoint(fromScreen: anchor, viewSize: view)
        camera.zoom(by: 2.5, anchor: anchor, viewSize: view)
        let after = camera.dataPoint(fromScreen: anchor, viewSize: view)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-9)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-9)
        let roundTrip = camera.screenPoint(fromData: after, viewSize: view)
        XCTAssertEqual(roundTrip.x, anchor.x, accuracy: 1e-9)
    }
}

final class ColormapTests: XCTestCase {
    func testLookupTableEndpoints() {
        let lut = Colormap.gray.lutBytes(size: 256)
        XCTAssertEqual(lut.count, 1024)
        XCTAssertEqual(Array(lut[0 ..< 4]), [0, 0, 0, 255])
        XCTAssertEqual(Array(lut[1020 ..< 1024]), [255, 255, 255, 255])
        XCTAssertEqual(Colormap.viridis.color(at: 0), RGBA(hex: 0x440154))
    }

    func testLabelColors() {
        XCTAssertEqual(LabelsLayer.color(for: 0).a, 0)
        XCTAssertNotEqual(LabelsLayer.color(for: 1), LabelsLayer.color(for: 2))
    }
}

final class LabelsLayerTests: XCTestCase {
    func testPaintUndoRedo() {
        let labels = LabelsLayer(shape: [2, 20, 20], name: "Labels")
        labels.selectedLabel = 3
        labels.brushSize = 4
        labels.stroke(to: SIMD2(5, 5), plane: [1])
        labels.stroke(to: SIMD2(15, 5), plane: [1])
        labels.endStroke()

        XCTAssertEqual(labels.data[[1, 5, 10]], 3, "the stroke is joined between samples")
        XCTAssertEqual(labels.data[[0, 5, 10]], 0, "other planes are untouched")
        XCTAssertTrue(labels.canUndo)

        labels.undo()
        XCTAssertTrue(labels.data.storage.allSatisfy { $0 == 0 })
        labels.redo()
        XCTAssertEqual(labels.data[[1, 5, 10]], 3)
    }

    func testEraseAndPick() {
        let labels = LabelsLayer(data: NDArray(shape: [4, 4], repeating: 7), name: "Labels")
        labels.pick(at: SIMD2(1.5, 1.5), plane: [])
        XCTAssertEqual(labels.selectedLabel, 7)
        labels.mode = .erase
        labels.brushSize = 1
        labels.stroke(to: SIMD2(0.5, 0.5), plane: [])
        labels.endStroke()
        XCTAssertEqual(labels.data[[0, 0]], 0)
        XCTAssertEqual(labels.data[[0, 1]], 7)
    }

    func testFillStopsAtBoundaries() {
        // A vertical wall of 1s at column 2 splits the plane in two.
        var data = NDArray<UInt32>(shape: [5, 5], repeating: 0)
        for row in 0 ..< 5 { data[[row, 2]] = 1 }
        let labels = LabelsLayer(data: data, name: "Labels")
        labels.selectedLabel = 9
        labels.fill(at: SIMD2(0.5, 0.5), plane: [])
        XCTAssertEqual(labels.data[[4, 1]], 9)
        XCTAssertEqual(labels.data[[4, 3]], 0)

        labels.undo()
        labels.contiguousFill = false
        labels.fill(at: SIMD2(0.5, 0.5), plane: [])
        XCTAssertEqual(labels.data[[4, 3]], 9)
        XCTAssertEqual(labels.data[[4, 2]], 1)
    }

    func testCancelStrokeRestoresPixels() {
        let labels = LabelsLayer(shape: [8, 8], name: "Labels")
        labels.stroke(to: SIMD2(1, 1), plane: [])
        labels.endStroke()
        labels.stroke(to: SIMD2(6, 6), plane: [])
        labels.cancelStroke()
        XCTAssertEqual(labels.data[[1, 1]], 1)
        XCTAssertEqual(labels.data[[6, 6]], 0)
        labels.undo()
        XCTAssertFalse(labels.canUndo, "the cancelled stroke left no undo entry")
    }

    func testStrokeOutsideTheImageIsIgnored() {
        let labels = LabelsLayer(shape: [4, 4], name: "Labels")
        labels.stroke(to: SIMD2(-50, -50), plane: [])
        labels.stroke(to: SIMD2(-40, 900), plane: [])
        labels.endStroke()
        XCTAssertFalse(labels.canUndo)
    }
}

final class TIFFTests: XCTestCase {
    func testRoundTripUInt32Labels() throws {
        let original = NDArray<UInt32>(shape: [3, 5, 7], storage: (0 ..< 105).map { UInt32($0 * 1000) })
        let read = try TIFFReader.read(TIFFWriter.data(for: original))
        XCTAssertEqual(read.shape, [3, 5, 7])
        XCTAssertEqual(read.storage, original.storage.map(Float.init))
    }

    func testRoundTripFloat4D() throws {
        let original = NDArray<Float>(shape: [2, 3, 4, 5], storage: (0 ..< 120).map { Float($0) * 0.25 - 3 })
        let read = try TIFFReader.read(TIFFWriter.data(for: original))
        XCTAssertEqual(read, original)
    }

    func testRoundTripUInt16Plane() throws {
        let original = NDArray<UInt16>(shape: [6, 9], storage: (0 ..< 54).map { UInt16($0 * 1200) })
        let read = try TIFFReader.read(TIFFWriter.data(for: original))
        XCTAssertEqual(read.shape, [6, 9])
        XCTAssertEqual(read.storage, original.storage.map(Float.init))
    }

    func testImageJHyperstackShape() {
        let description = "ImageJ=1.54f\nimages=24\nchannels=2\nslices=4\nframes=3\nhyperstack=true\n"
        XCTAssertEqual(TIFFReader.inferShape(description: description, pageCount: 24, height: 10, width: 20),
                       [3, 4, 2, 10, 20])
        XCTAssertEqual(TIFFReader.inferShape(description: nil, pageCount: 5, height: 10, width: 20), [5, 10, 20])
        XCTAssertEqual(TIFFReader.inferShape(description: nil, pageCount: 1, height: 10, width: 20), [10, 20])
    }

    func testRejectsNonTIFF() {
        XCTAssertThrowsError(try TIFFReader.read(Data("hello world".utf8))) { error in
            XCTAssertEqual(error as? TIFFError, .notATIFF)
        }
    }
}

final class SampleDataTests: XCTestCase {
    func testBlobsAreDeterministic() {
        let a = SampleData.blobs(shape: [4, 32, 32], count: 5, seed: 7)
        let b = SampleData.blobs(shape: [4, 32, 32], count: 5, seed: 7)
        XCTAssertEqual(a, b)
        XCTAssertGreaterThan(a.finiteRange()!.upperBound, 0.3)
    }
}
