import Foundation
import Observation

public enum ShapeType: String, CaseIterable, Identifiable, Sendable {
    case rectangle
    case ellipse
    case polygon
    case line
    case path

    public var id: String { rawValue }

    /// Closed shapes have a fill; lines and paths only an edge.
    public var isClosed: Bool {
        switch self {
        case .rectangle, .ellipse, .polygon: return true
        case .line, .path: return false
        }
    }
}

/// One 2D shape lying in a single plane of the data.
public struct VectorShape: Equatable, Sendable {
    public var type: ShapeType
    /// Vertices as (x, y) data coordinates. Rectangles and ellipses store the four corners
    /// of their bounding box, as napari does.
    public var vertices: [SIMD2<Double>]
    /// Coordinates on the non-displayed axes, e.g. the z of the slice it was drawn on.
    public var leading: [Double]

    public init(type: ShapeType, vertices: [SIMD2<Double>], leading: [Double] = []) {
        self.type = type
        self.vertices = vertices
        self.leading = leading
    }

    /// The outline to draw: ellipses become 64-gons, everything else is its vertices.
    public var outline: [SIMD2<Double>] {
        guard type == .ellipse, let first = vertices.first else { return vertices }
        var lo = first
        var hi = first
        for v in vertices {
            lo = pointwiseMin(lo, v)
            hi = pointwiseMax(hi, v)
        }
        let center = (lo + hi) / 2
        let radii = (hi - lo) / 2
        return (0 ..< 64).map { i in
            let angle = Double(i) / 64 * 2 * Double.pi
            return center + radii * SIMD2(cos(angle), sin(angle))
        }
    }

    /// Whether `point` hits the shape: inside a closed shape, or within `tolerance` of its edge.
    public func contains(_ point: SIMD2<Double>, tolerance: Double) -> Bool {
        let outline = self.outline
        if type.isClosed, Geometry.polygon(outline, contains: point) { return true }
        let segments = type.isClosed ? outline.count : outline.count - 1
        for i in 0 ..< max(0, segments) {
            let a = outline[i]
            let b = outline[(i + 1) % outline.count]
            if Geometry.distance(from: point, toSegment: a, b) <= tolerance { return true }
        }
        return outline.count == 1 && Geometry.length(outline[0] - point) <= tolerance
    }
}

public enum ShapesMode: String, CaseIterable, Identifiable, Sendable {
    case panZoom = "pan/zoom"
    case select
    case rectangle
    case ellipse
    case polygon
    case line
    case path

    public var id: String { rawValue }

    /// The shape this mode draws, if it is a drawing mode.
    public var shapeType: ShapeType? {
        switch self {
        case .panZoom, .select: return nil
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .polygon: return .polygon
        case .line: return .line
        case .path: return .path
        }
    }
}

/// Vector annotations, like napari's Shapes layer.
@Observable
public final class ShapesLayer: Layer {
    public let id = UUID()
    public let props: LayerProperties
    public private(set) var shapes: [VectorShape]
    public let extent: [Int]
    public private(set) var dataVersion = 0

    public var mode: ShapesMode = .rectangle {
        didSet { if mode != oldValue { finishDraft() } }
    }
    /// Edge width in data pixels.
    public var edgeWidth: Double = 2
    public var edgeColor = RGBA(1, 0.85, 0.1)
    public var faceColor = RGBA(1, 0.85, 0.1, 0.2)
    public var selection: Set<Int> = []
    /// The shape being drawn, shown but not yet part of `shapes`.
    public private(set) var draft: VectorShape?

    public var shape: [Int] { extent }

    public init(extent: [Int], shapes: [VectorShape] = [], name: String) {
        precondition(extent.count >= 2, "shapes layers need at least two dimensions")
        self.extent = extent
        self.shapes = shapes
        self.props = LayerProperties(name: name, blending: .translucent)
    }

    /// Indices of the shapes on the plane selected by `leading`.
    public func visibleIndices(plane leading: [Int]) -> [Int] {
        shapes.indices.filter { index in
            zip(shapes[index].leading, leading).allSatisfy { abs($0 - Double($1)) < 0.5 }
        }
    }

    /// The topmost visible shape under `point`.
    public func shapeIndex(at point: SIMD2<Double>, plane leading: [Int], tolerance: Double) -> Int? {
        visibleIndices(plane: leading).last { index in
            shapes[index].contains(point, tolerance: tolerance + edgeWidth / 2)
        }
    }

    // MARK: Drawing

    /// Starts a rectangle, ellipse, line or path at `point`, or adds a polygon vertex.
    /// For polygons, a tap within `closeDistance` of the first vertex closes the shape.
    public func beginDraft(at point: SIMD2<Double>, plane leading: [Int], closeDistance: Double) {
        guard let type = mode.shapeType else { return }
        if type == .polygon, var polygon = draft {
            if polygon.vertices.count >= 3, Geometry.length(point - polygon.vertices[0]) <= closeDistance {
                finishDraft()
            } else {
                polygon.vertices.append(point)
                draft = polygon
            }
            return
        }
        // Two-point shapes start with a vertex that follows the drag; paths and polygons grow.
        let start = type == .path || type == .polygon ? [point] : [point, point]
        draft = VectorShape(type: type, vertices: start, leading: leading.map { Double($0) })
    }

    /// Follows the touch: moves the last vertex, or extends a path by points at least
    /// `minimumSpacing` apart.
    public func updateDraft(to point: SIMD2<Double>, minimumSpacing: Double) {
        guard var shape = draft, let last = shape.vertices.last else { return }
        if shape.type == .path {
            guard Geometry.length(point - last) >= minimumSpacing else { return }
            shape.vertices.append(point)
        } else {
            shape.vertices[shape.vertices.count - 1] = point
        }
        draft = shape
    }

    /// Ends a drag. Polygons keep drafting until closed or finished explicitly.
    public func endDrag() {
        if draft?.type != .polygon { finishDraft() }
    }

    /// Commits the draft, discarding it if it is degenerate.
    public func finishDraft() {
        guard var shape = draft else { return }
        draft = nil
        switch shape.type {
        case .rectangle, .ellipse:
            let a = shape.vertices[0]
            let b = shape.vertices[shape.vertices.count - 1]
            guard a.x != b.x, a.y != b.y else { return }
            shape.vertices = [a, SIMD2(b.x, a.y), b, SIMD2(a.x, b.y)]
        case .polygon:
            guard shape.vertices.count >= 3 else { return }
        case .line, .path:
            guard shape.vertices.count >= 2, shape.vertices.first != shape.vertices.last || shape.vertices.count > 2
            else { return }
        }
        shapes.append(shape)
        selection = [shapes.count - 1]
        dataVersion += 1
    }

    public func cancelDraft() {
        draft = nil
    }

    /// Undoes the current touch, e.g. when it turns into a two-finger pan: a polygon loses
    /// its newest vertex, any other draft is discarded.
    public func cancelDraftTouch() {
        guard var shape = draft, shape.type == .polygon, shape.vertices.count > 1 else {
            draft = nil
            return
        }
        shape.vertices.removeLast()
        draft = shape
    }

    // MARK: Editing

    public func move(_ index: Int, by delta: SIMD2<Double>) {
        guard shapes.indices.contains(index) else { return }
        shapes[index].vertices = shapes[index].vertices.map { $0 + delta }
        dataVersion += 1
    }

    public func removeSelected() {
        guard !selection.isEmpty else { return }
        shapes = shapes.enumerated().filter { !selection.contains($0.offset) }.map(\.element)
        selection = []
        dataVersion += 1
    }

    // MARK: CSV, compatible with napari's shapes reader and writer

    /// One row per vertex: `index,shape-type,vertex-index,axis-0,…`, coordinates in (…, y, x) order.
    public func csv() -> String {
        let axes = (0 ..< extent.count).map { "axis-\($0)" }
        var lines = ["index,shape-type,vertex-index," + axes.joined(separator: ",")]
        for (index, shape) in shapes.enumerated() {
            for (vertexIndex, vertex) in shape.vertices.enumerated() {
                let coordinates = shape.leading + [vertex.y, vertex.x]
                let fields = [String(index), shape.type.rawValue, String(vertexIndex)] + coordinates.map { String($0) }
                lines.append(fields.joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func parseCSV(_ text: String) throws -> [VectorShape] {
        var lines = text.split(whereSeparator: \.isNewline).map { $0.split(separator: ",", omittingEmptySubsequences: false) }
        guard !lines.isEmpty else { return [] }
        let header = lines.removeFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        guard let indexColumn = header.firstIndex(of: "index"),
              let typeColumn = header.firstIndex(of: "shape-type")
        else { throw CSVError.missingColumns }
        let axisColumns = header.indices
            .compactMap { column -> (axis: Int, column: Int)? in
                guard header[column].hasPrefix("axis-"), let axis = Int(header[column].dropFirst(5)) else { return nil }
                return (axis, column)
            }
            .sorted { $0.axis < $1.axis }
            .map(\.column)
        guard axisColumns.count >= 2 else { throw CSVError.missingColumns }

        var shapes: [VectorShape] = []
        var currentIndex: String?
        for (row, fields) in lines.enumerated() {
            func field(_ column: Int) -> String? {
                column < fields.count ? fields[column].trimmingCharacters(in: .whitespaces) : nil
            }
            guard let index = field(indexColumn),
                  let type = field(typeColumn).flatMap(ShapeType.init(rawValue:))
            else { throw CSVError.badRow(line: row + 2) }
            let coordinates = try axisColumns.map { column -> Double in
                guard let value = field(column).flatMap({ Double($0) }) else { throw CSVError.badRow(line: row + 2) }
                return value
            }
            let vertex = SIMD2(coordinates[coordinates.count - 1], coordinates[coordinates.count - 2])
            if index != currentIndex {
                shapes.append(VectorShape(type: type, vertices: [], leading: Array(coordinates.dropLast(2))))
                currentIndex = index
            }
            shapes[shapes.count - 1].vertices.append(vertex)
        }
        return shapes
    }

    public enum CSVError: Error, LocalizedError, Equatable {
        case missingColumns
        case badRow(line: Int)

        public var errorDescription: String? {
            switch self {
            case .missingColumns: return "The CSV needs index, shape-type and axis-0, axis-1, … columns."
            case .badRow(let line): return "Line \(line) of the CSV has a missing or invalid value."
            }
        }
    }
}

/// Plane geometry used for drawing and hit testing shapes.
public enum Geometry {
    public static func length(_ v: SIMD2<Double>) -> Double {
        (v * v).sum().squareRoot()
    }

    static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        a.x * b.y - a.y * b.x
    }

    /// Twice-halved shoelace area: positive for counter-clockwise in a y-up frame.
    public static func signedArea(_ polygon: [SIMD2<Double>]) -> Double {
        var area = 0.0
        for i in polygon.indices {
            area += cross(polygon[i], polygon[(i + 1) % polygon.count])
        }
        return area / 2
    }

    public static func distance(from p: SIMD2<Double>, toSegment a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let lengthSquared = (ab * ab).sum()
        let t = lengthSquared > 0 ? min(max(((p - a) * ab).sum() / lengthSquared, 0), 1) : 0
        return length(p - (a + ab * t))
    }

    /// Even-odd point-in-polygon test.
    public static func polygon(_ polygon: [SIMD2<Double>], contains p: SIMD2<Double>) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Ear-clipping triangulation of a simple polygon, as index triples into `polygon`.
    /// Falls back to a fan for the remainder if the polygon self-intersects.
    public static func triangulate(_ polygon: [SIMD2<Double>]) -> [(Int, Int, Int)] {
        guard polygon.count >= 3 else { return [] }
        var remaining = Array(polygon.indices)
        if signedArea(polygon) < 0 { remaining.reverse() }
        var triangles: [(Int, Int, Int)] = []

        func isEar(_ i: Int) -> Bool {
            let n = remaining.count
            let (prev, current, next) = (remaining[(i + n - 1) % n], remaining[i], remaining[(i + 1) % n])
            let (a, b, c) = (polygon[prev], polygon[current], polygon[next])
            guard cross(b - a, c - b) > 0 else { return false } // reflex or degenerate corner
            for j in remaining where j != prev && j != current && j != next {
                let p = polygon[j]
                if cross(b - a, p - a) >= 0, cross(c - b, p - b) >= 0, cross(a - c, p - c) >= 0 {
                    return false
                }
            }
            return true
        }

        while remaining.count > 3 {
            guard let ear = remaining.indices.first(where: isEar) else { break }
            let n = remaining.count
            triangles.append((remaining[(ear + n - 1) % n], remaining[ear], remaining[(ear + 1) % n]))
            remaining.remove(at: ear)
        }
        for i in 1 ..< remaining.count - 1 {
            triangles.append((remaining[0], remaining[i], remaining[i + 1]))
        }
        return triangles
    }
}
