/// A dense, row-major n-dimensional array.
///
/// This is the minimal stand-in for a numpy array: a flat `storage` buffer plus a
/// `shape`. The last two axes are always the displayed (y, x) plane, so a 2-D slice
/// for any set of leading indices is a contiguous run of `storage`.
public struct NDArray<Element> {
    public let shape: [Int]
    public let strides: [Int]
    public var storage: [Element]

    public init(shape: [Int], storage: [Element]) {
        precondition(!shape.isEmpty, "NDArray needs at least one axis")
        precondition(shape.allSatisfy { $0 > 0 }, "NDArray axes must be non-empty, got \(shape)")
        precondition(storage.count == shape.reduce(1, *),
                     "storage has \(storage.count) elements, shape \(shape) needs \(shape.reduce(1, *))")
        self.shape = shape
        self.strides = NDArray.rowMajorStrides(for: shape)
        self.storage = storage
    }

    public init(shape: [Int], repeating value: Element) {
        self.init(shape: shape, storage: Array(repeating: value, count: shape.reduce(1, *)))
    }

    public var ndim: Int { shape.count }
    public var count: Int { storage.count }

    static func rowMajorStrides(for shape: [Int]) -> [Int] {
        var strides = Array(repeating: 1, count: shape.count)
        var accumulated = 1
        for axis in stride(from: shape.count - 1, through: 0, by: -1) {
            strides[axis] = accumulated
            accumulated *= shape[axis]
        }
        return strides
    }

    public func offset(of index: [Int]) -> Int {
        precondition(index.count == ndim, "index \(index) does not match shape \(shape)")
        var offset = 0
        for (i, stride) in zip(index, strides) { offset += i * stride }
        return offset
    }

    public subscript(_ index: [Int]) -> Element {
        get { storage[offset(of: index)] }
        set { storage[offset(of: index)] = newValue }
    }

    // MARK: Planes (the last two axes)

    public var planeHeight: Int { ndim >= 2 ? shape[ndim - 2] : 1 }
    public var planeWidth: Int { shape[ndim - 1] }
    public var planeCount: Int { planeHeight * planeWidth }
    /// The axes that are not part of the displayed plane.
    public var leadingShape: [Int] { Array(shape.dropLast(2)) }

    /// Offset of the first element of the plane selected by `leading`
    /// (one index per leading axis).
    public func planeOffset(_ leading: [Int]) -> Int {
        precondition(leading.count == leadingShape.count,
                     "expected \(leadingShape.count) leading indices, got \(leading.count)")
        var offset = 0
        for (i, stride) in zip(leading, strides) { offset += i * stride }
        return offset
    }

    public func plane(at leading: [Int]) -> ArraySlice<Element> {
        let start = planeOffset(leading)
        return storage[start ..< start + planeCount]
    }

    // MARK: Volumes (the last three axes)

    /// Depth, height and width of the trailing three axes.
    public var volumeShape: (depth: Int, height: Int, width: Int)? {
        ndim >= 3 ? (shape[ndim - 3], shape[ndim - 2], shape[ndim - 1]) : nil
    }

    /// The (z, y, x) block selected by one index per axis before the last three.
    public func volume(at leading: [Int]) -> ArraySlice<Element> {
        precondition(ndim >= 3 && leading.count == ndim - 3,
                     "expected \(ndim - 3) leading indices for shape \(shape)")
        var start = 0
        for (i, stride) in zip(leading, strides) { start += i * stride }
        return storage[start ..< start + strides[ndim - 3] * shape[ndim - 3]]
    }

    public func map<T>(_ transform: (Element) throws -> T) rethrows -> NDArray<T> {
        NDArray<T>(shape: shape, storage: try storage.map(transform))
    }
}

extension NDArray: Equatable where Element: Equatable {}
extension NDArray: Sendable where Element: Sendable {}

extension NDArray where Element == Float {
    /// Minimum and maximum of all finite values, or nil if there are none.
    public func finiteRange() -> ClosedRange<Float>? {
        var lo = Float.infinity
        var hi = -Float.infinity
        for value in storage where value.isFinite {
            if value < lo { lo = value }
            if value > hi { hi = value }
        }
        return lo <= hi ? lo ... hi : nil
    }
}
