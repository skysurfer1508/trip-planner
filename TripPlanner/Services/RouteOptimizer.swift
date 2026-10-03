import Foundation
import CoreLocation

/// Orders stops to shorten the walk: nearest neighbour from the first stop, then 2-opt clean-up.
/// The first stop stays first (usually the hotel or the day's starting point).
enum RouteOptimizer {
    /// Returns the new order as indices into `coordinates`.
    static func order(_ coordinates: [CLLocationCoordinate2D]) -> [Int] {
        let count = coordinates.count
        guard count > 2 else { return Array(coordinates.indices) }

        func distance(_ a: Int, _ b: Int) -> Double {
            RoutingService.straightLine(from: coordinates[a], to: coordinates[b])
        }

        var route = [0]
        var remaining = Set(1..<count)
        while !remaining.isEmpty {
            let last = route[route.count - 1]
            guard let next = remaining.min(by: { distance(last, $0) < distance(last, $1) }) else { break }
            route.append(next)
            remaining.remove(next)
        }

        // 2-opt: reverse a stretch whenever that shortens the path.
        var improved = true
        var rounds = 0
        while improved && rounds < 50 {
            improved = false
            rounds += 1
            for i in 1..<(count - 1) {
                for j in (i + 1)..<count {
                    let tail = j + 1 < count
                    let before = distance(route[i - 1], route[i]) + (tail ? distance(route[j], route[j + 1]) : 0)
                    let after = distance(route[i - 1], route[j]) + (tail ? distance(route[i], route[j + 1]) : 0)
                    if after + 1e-6 < before {
                        route[i...j].reverse()
                        improved = true
                    }
                }
            }
        }
        return route
    }

    /// Total straight-line length of the path, in meters.
    static func length(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        zip(coordinates, coordinates.dropFirst()).reduce(0) {
            $0 + RoutingService.straightLine(from: $1.0, to: $1.1)
        }
    }
}
