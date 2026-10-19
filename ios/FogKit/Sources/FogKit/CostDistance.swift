import Foundation

// Terrain cost distance for fog routing. Port of
// backend/app/services/cost_distance.py.
//
// Replaces "how far apart are these points" with "what is the cheapest path the
// marine air could take between them", where climbing towards the inversion is
// expensive and rising through it is impossible. An observation in the Sunset
// can then only reach the Mission by routing through the Golden Gate or the San
// Bruno Gap -- which is how the air itself gets there.
//
// The Python builds a scipy sparse matrix and runs csgraph.dijkstra. Here the
// graph is implicit: a cell's 8 neighbours and their edge costs are computed
// from the elevation grid as Dijkstra visits it, which is the same graph
// without allocating ~1.4M edges per request.

/// (row shift, column shift) for an 8-connected grid. Row 0 is north.
private let neighbourOffsets: [(Int, Int)] = [
    (-1, 0), (1, 0), (0, -1), (0, 1),
    (-1, -1), (-1, 1), (1, -1), (1, 1),
]

let minDistanceM = 1.0

/// The traversal graph for one fog top.
///
/// An edge costs its horizontal length times a penalty that grows once the
/// higher of its two cells rises above the fog top, and the edge disappears
/// once that crest clears the top by `blockBufferM`. It depends on the top, so
/// it is rebuilt per request -- which costs nothing here, since it is implicit.
public struct CostSurface: Sendable {
    public let elevation: Grid<Double>
    public let fogTopM: Double
    public let beta: Double
    public let scaleM: Double
    public let blockBufferM: Double
    private let spans: [Double]

    public init(
        elevation: Grid<Double>, cellDyM: Double, cellDxM: Double, fogTopM: Double,
        beta: Double = 12, scaleM: Double = 60, blockBufferM: Double = 25
    ) {
        self.elevation = elevation
        self.fogTopM = fogTopM
        self.beta = beta
        self.scaleM = scaleM
        self.blockBufferM = blockBufferM
        spans = neighbourOffsets.map { hypot(Double($0.0) * cellDyM, Double($0.1) * cellDxM) }
    }

    /// Cost distance from one source cell to every cell. Cells walled off by
    /// terrain above the inversion are `.infinity`.
    public func distances(from source: Int) -> [Double] {
        let rows = elevation.height, cols = elevation.width
        let ground = elevation.values
        let impassableAbove = fogTopM + blockBufferM
        let scale = max(scaleM, 1e-6)

        var distance = [Double](repeating: .infinity, count: ground.count)
        var heap = MinHeap()
        distance[source] = 0
        heap.push(0, source)

        while let (d, node) = heap.pop() {
            if d > distance[node] { continue }
            let row = node / cols, col = node % cols
            let here = ground[node]
            for (k, (dr, dc)) in neighbourOffsets.enumerated() {
                let r = row + dr, c = col + dc
                guard r >= 0, r < rows, c >= 0, c < cols else { continue }
                let next = r * cols + c
                let crest = max(here, ground[next])
                guard crest <= impassableAbove else { continue }
                let penalty = 1 + beta * max(0, (crest - fogTopM) / scale)
                let candidate = d + spans[k] * penalty
                if candidate < distance[next] {
                    distance[next] = candidate
                    heap.push(candidate, next)
                }
            }
        }
        return distance
    }
}

/// Straight-line distances in metres from one point to every cell, for the
/// no-terrain-routing baseline.
func geographicDistances(geometry: RasterGeometry, latitude: Double, longitude: Double) -> [Double] {
    let meanLat = (0..<geometry.gridY).map(geometry.latitude(row:)).reduce(0, +)
        / Double(geometry.gridY) * .pi / 180
    let metresPerDegLat = 111_320.0
    let metresPerDegLon = 111_320.0 * cos(meanLat)
    var out = [Double](repeating: 0, count: geometry.gridX * geometry.gridY)
    for row in 0..<geometry.gridY {
        let dNorth = (geometry.latitude(row: row) - latitude) * metresPerDegLat
        for col in 0..<geometry.gridX {
            let dEast = (geometry.longitude(col: col) - longitude) * metresPerDegLon
            out[row * geometry.gridX + col] = hypot(dNorth, dEast)
        }
    }
    return out
}

/// Inverse-distance weighting over cost distance, accumulated one station at
/// a time so only one distance field per worker is ever held in memory.
///
/// Cells no station can reach get zero influence and are flagged unreachable,
/// which for fog is the correct answer: no marine air, no fog.
struct InverseDistanceWeighting {
    let power: Double
    private(set) var weightSum: [Double]
    private(set) var numerator: [Double]

    init(cellCount: Int, power: Double) {
        self.power = power
        weightSum = [Double](repeating: 0, count: cellCount)
        numerator = [Double](repeating: 0, count: cellCount)
    }

    /// Stations must be added in a fixed order: floating-point sums depend on
    /// it, and the backend adds them in station order.
    mutating func add(distances: [Double], value: Double) {
        for i in distances.indices where distances[i].isFinite {
            let weight = pow(max(distances[i], minDistanceM), -power)
            weightSum[i] += weight
            numerator[i] += weight * value
        }
    }

    func result() -> (interpolated: [Double], reachable: [Bool]) {
        let reachable = weightSum.map { $0 > 0 }
        let interpolated = weightSum.indices.map { reachable[$0] ? numerator[$0] / weightSum[$0] : 0 }
        return (interpolated, reachable)
    }
}

/// Runs `work` for every index on all cores, then hands results to `consume`
/// strictly in index order, a core-count batch at a time.
func forEachInParallel<T>(
    _ count: Int, work: (Int) -> T, consume: (Int, T) -> Void
) {
    let batch = max(1, ProcessInfo.processInfo.activeProcessorCount)
    var start = 0
    while start < count {
        let end = min(start + batch, count)
        let results = UnsafeMutableBufferPointer<T?>.allocate(capacity: end - start)
        results.initialize(repeating: nil)
        // Each iteration writes only its own slot, so the shared buffer is safe.
        nonisolated(unsafe) let slots = results
        let first = start
        withoutActuallyEscaping(work) { work in
            nonisolated(unsafe) let work = work
            DispatchQueue.concurrentPerform(iterations: end - first) { offset in
                slots[offset] = work(first + offset)
            }
        }
        for offset in 0..<(end - start) { consume(start + offset, results[offset]!) }
        results.deinitialize()
        results.deallocate()
        start = end
    }
}

/// A binary min-heap of (distance, cell), with lazy deletion left to the caller.
private struct MinHeap {
    private var keys: [Double] = []
    private var cells: [Int32] = []

    mutating func push(_ key: Double, _ cell: Int) {
        keys.append(key)
        cells.append(Int32(cell))
        var child = keys.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard keys[child] < keys[parent] else { break }
            keys.swapAt(child, parent)
            cells.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard let top = keys.first else { return nil }
        let cell = Int(cells[0])
        let lastKey = keys.removeLast(), lastCell = cells.removeLast()
        if !keys.isEmpty {
            keys[0] = lastKey
            cells[0] = lastCell
            var parent = 0
            while true {
                let left = 2 * parent + 1, right = left + 1
                var smallest = parent
                if left < keys.count, keys[left] < keys[smallest] { smallest = left }
                if right < keys.count, keys[right] < keys[smallest] { smallest = right }
                if smallest == parent { break }
                keys.swapAt(parent, smallest)
                cells.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return (top, cell)
    }
}
