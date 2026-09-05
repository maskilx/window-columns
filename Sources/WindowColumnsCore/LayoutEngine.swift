import CoreGraphics
import Foundation

public enum ColumnLayoutError: Error {
    case insufficientSpace
}

/// Whether a set of windows can be tiled across a display at all.
///
/// Some windows refuse to go below a certain width — a fixed-size utility, a
/// video call, an app with a wide minimum. Discovering that only while writing
/// frames leaves the group half-applied, so callers check first.
public struct ColumnFit: Equatable, Sendable {
    public let required: CGFloat
    public let available: CGFloat

    public var fits: Bool { available + 0.5 >= required }
    public var overflow: CGFloat { max(0, required - available) }

    public init(required: CGFloat, available: CGFloat) {
        self.required = required
        self.available = available
    }
}

public struct ColumnLayoutEngine {
    /// Uniform outer padding, separate from the gaps between columns.
    public static func contentFrame(in frame: CGRect, padding: CGFloat) -> CGRect {
        let requested = padding.isFinite ? max(0, padding) : 0
        let inset = min(requested, max(0, (min(frame.width, frame.height) - 1) / 2))
        return frame.insetBy(dx: inset, dy: inset)
    }

    /// The width these windows need against the width the display offers.
    public static func fit(
        in visibleWidth: CGFloat,
        minimumWidths: [CGFloat],
        gap: CGFloat
    ) -> ColumnFit {
        let count = minimumWidths.count
        guard count > 0 else { return ColumnFit(required: 0, available: visibleWidth) }
        return ColumnFit(
            required: minimumWidths.reduce(0, +),
            available: visibleWidth - gap * CGFloat(count - 1)
        )
    }

    public static func nearestColumnIndex(to horizontalCenter: CGFloat, in frames: [CGRect]) -> Int? {
        frames.indices.min {
            abs(frames[$0].midX - horizontalCenter) < abs(frames[$1].midX - horizontalCenter)
        }
    }

    public static func frames(
        in visibleFrame: CGRect,
        ratios proposedRatios: [CGFloat],
        minimumWidths: [CGFloat],
        gap: CGFloat
    ) throws -> [CGRect] {
        let count = minimumWidths.count
        guard count > 0, proposedRatios.count == count else { return [] }

        let available = visibleFrame.width - gap * CGFloat(count - 1)
        guard available >= minimumWidths.reduce(0, +) else {
            throw ColumnLayoutError.insufficientSpace
        }

        var ratios = proposedRatios.map { max(0, $0) }
        let ratioTotal = ratios.reduce(0, +)
        if ratioTotal <= 0 {
            ratios = Array(repeating: 1 / CGFloat(count), count: count)
        } else {
            ratios = ratios.map { $0 / ratioTotal }
        }

        var widths = Array(repeating: CGFloat.zero, count: count)
        var flexible = Set(0..<count)
        var remaining = available
        var remainingRatio = ratios.reduce(0, +)

        while !flexible.isEmpty {
            var constrained: [Int] = []
            for index in flexible {
                let candidate = remainingRatio > 0 ? remaining * ratios[index] / remainingRatio : remaining / CGFloat(flexible.count)
                if candidate < minimumWidths[index] {
                    widths[index] = minimumWidths[index]
                    constrained.append(index)
                }
            }
            if constrained.isEmpty { break }
            for index in constrained {
                flexible.remove(index)
                remaining -= widths[index]
                remainingRatio -= ratios[index]
            }
        }

        for index in flexible {
            widths[index] = remainingRatio > 0 ? remaining * ratios[index] / remainingRatio : remaining / CGFloat(flexible.count)
        }

        var result: [CGRect] = []
        var x = visibleFrame.minX
        for index in 0..<count {
            let width = index == count - 1 ? visibleFrame.maxX - x : widths[index]
            result.append(CGRect(x: x, y: visibleFrame.minY, width: width, height: visibleFrame.height))
            x += width + gap
        }
        return result
    }

    public static func adjustedRatios(
        afterResizing index: Int,
        to newWidth: CGFloat,
        currentWidths: [CGFloat],
        minimumWidths: [CGFloat]
    ) -> [CGFloat] {
        guard currentWidths.indices.contains(index), currentWidths.count == minimumWidths.count else { return currentWidths }
        var widths = currentWidths
        let total = widths.reduce(0, +)
        let otherMinimums = minimumWidths.enumerated().filter { $0.offset != index }.map(\.element).reduce(0, +)
        let clampedNewWidth = max(minimumWidths[index], min(newWidth, total - otherMinimums))
        var delta = clampedNewWidth - widths[index]
        widths[index] = clampedNewWidth

        let neighborOrder = Array((index + 1)..<widths.count) + Array((0..<index).reversed())
        if delta > 0 {
            for neighbor in neighborOrder where delta > 0 {
                let available = max(0, widths[neighbor] - minimumWidths[neighbor])
                let consumed = min(delta, available)
                widths[neighbor] -= consumed
                delta -= consumed
            }
        } else if delta < 0, let neighbor = neighborOrder.first {
            widths[neighbor] -= delta
        }

        if delta > 0 { widths[index] -= delta }
        return widths.map { $0 / total }
    }

    /// Moves the divider between `leftIndex` and the following column. A positive
    /// delta moves the divider right; only the two windows touching it change.
    public static func adjustedRatios(
        movingDividerAfter leftIndex: Int,
        by proposedDelta: CGFloat,
        currentWidths: [CGFloat],
        minimumWidths: [CGFloat]
    ) -> [CGFloat] {
        let rightIndex = leftIndex + 1
        guard currentWidths.indices.contains(leftIndex),
              currentWidths.indices.contains(rightIndex),
              currentWidths.count == minimumWidths.count else { return currentWidths }

        var widths = currentWidths
        let total = widths.reduce(0, +)
        guard total > 0 else { return currentWidths }

        let maximumLeftward = minimumWidths[leftIndex] - widths[leftIndex]
        let maximumRightward = widths[rightIndex] - minimumWidths[rightIndex]
        let delta = min(max(proposedDelta, maximumLeftward), maximumRightward)
        widths[leftIndex] += delta
        widths[rightIndex] -= delta
        return widths.map { $0 / total }
    }
}

/// How a grouped window has drifted from the slot it is supposed to occupy.
public enum ColumnDisplacement: Equatable, Sendable {
    /// Still in its slot, within tolerance. Nothing to do.
    case inPlace
    /// Same size, different position: the user dragged it. Snap it back, and
    /// reorder the group if its centre crossed into another column.
    case moved
    /// Its size changed, so the user resized it. The connected-resize path owns
    /// this; forcing it back to the slot would discard their resize.
    case resized

    public init(actual: CGRect, target: CGRect, tolerance: CGFloat = 2) {
        let keptItsSize = abs(actual.width - target.width) <= tolerance
            && abs(actual.height - target.height) <= tolerance
        guard keptItsSize else {
            self = .resized
            return
        }
        let inPlace = abs(actual.minX - target.minX) <= tolerance
            && abs(actual.minY - target.minY) <= tolerance
        self = inPlace ? .inPlace : .moved
    }
}
