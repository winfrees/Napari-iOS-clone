import Foundation
import Observation

public enum PointsMode: String, CaseIterable, Identifiable, Sendable {
    case panZoom = "pan/zoom"
    case add
    case select

    public var id: String { rawValue }
}

/// N-D point annotations, like napari's Points layer.
///
/// Each point has one coordinate per axis, in the same (…, y, x) order as image data.
/// In 2D a point is shown when it lies within half a step of the current slice.
@Observable
public final class PointsLayer: Layer {
    public let id = UUID()
    public let props: LayerProperties
    public private(set) var points: [[Double]]
    /// Extent of the layer for the viewer's dims, usually the shape of the image being annotated.
    public let extent: [Int]
    public private(set) var dataVersion = 0

    public var mode: PointsMode = .add
    /// Point diameter in data pixels.
    public var size: Double = 10
    public var faceColor = RGBA(1, 1, 1)
    public var borderColor = RGBA(0, 0, 0)
    public var selection: Set<Int> = []

    public var shape: [Int] { extent }

    public init(extent: [Int], points: [[Double]] = [], name: String) {
        precondition(extent.count >= 2, "points layers need at least two dimensions")
        precondition(points.allSatisfy { $0.count == extent.count }, "every point needs \(extent.count) coordinates")
        self.extent = extent
        self.points = points
        self.props = LayerProperties(name: name, blending: .translucent)
    }

    // MARK: Editing

    @discardableResult
    public func add(_ coordinates: [Double]) -> Int {
        precondition(coordinates.count == extent.count, "a point needs \(extent.count) coordinates")
        points.append(coordinates)
        dataVersion += 1
        return points.count - 1
    }

    public func move(_ index: Int, to coordinates: [Double]) {
        guard points.indices.contains(index), coordinates.count == extent.count else { return }
        points[index] = coordinates
        dataVersion += 1
    }

    public func removeSelected() {
        guard !selection.isEmpty else { return }
        points = points.enumerated().filter { !selection.contains($0.offset) }.map(\.element)
        selection = []
        dataVersion += 1
    }

    // MARK: Slicing and hit testing

    /// Indices of the points in the plane selected by `leading` (one index per non-displayed axis).
    public func visibleIndices(plane leading: [Int]) -> [Int] {
        points.indices.filter { index in
            zip(points[index], leading).allSatisfy { abs($0 - Double($1)) < 0.5 }
        }
    }

    /// The visible point nearest `location` (x, y in data coordinates), if any lies within `radius`.
    public func nearestVisible(to location: SIMD2<Double>, plane leading: [Int], within radius: Double) -> Int? {
        var best: (index: Int, distance: Double)?
        for index in visibleIndices(plane: leading) {
            let p = points[index]
            let d = SIMD2(p[p.count - 1], p[p.count - 2]) - location
            let distance = (d * d).sum().squareRoot()
            if distance <= radius, distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best?.index
    }

    // MARK: CSV, compatible with napari's points reader and writer

    public func csv() -> String {
        var lines = ["index," + (0 ..< extent.count).map { "axis-\($0)" }.joined(separator: ",")]
        for (index, point) in points.enumerated() {
            lines.append(([String(index)] + point.map { String($0) }).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads the `axis-N` columns of a napari points CSV. Other columns are ignored.
    public static func parseCSV(_ text: String) throws -> [[Double]] {
        var lines = text.split(whereSeparator: \.isNewline).map { $0.split(separator: ",", omittingEmptySubsequences: false) }
        guard !lines.isEmpty else { return [] }
        let header = lines.removeFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        let axisColumns = header.indices
            .compactMap { column -> (axis: Int, column: Int)? in
                guard header[column].hasPrefix("axis-"), let axis = Int(header[column].dropFirst(5)) else { return nil }
                return (axis, column)
            }
            .sorted { $0.axis < $1.axis }
        guard axisColumns.count >= 2 else { throw CSVError.noAxisColumns }
        return try lines.enumerated().map { row, fields in
            try axisColumns.map { axis in
                guard axis.column < fields.count,
                      let value = Double(fields[axis.column].trimmingCharacters(in: .whitespaces))
                else { throw CSVError.badValue(line: row + 2) }
                return value
            }
        }
    }

    public enum CSVError: Error, LocalizedError, Equatable {
        case noAxisColumns
        case badValue(line: Int)

        public var errorDescription: String? {
            switch self {
            case .noAxisColumns: return "The CSV has no axis-0, axis-1, … columns."
            case .badValue(let line): return "Line \(line) of the CSV has a missing or non-numeric coordinate."
            }
        }
    }
}
