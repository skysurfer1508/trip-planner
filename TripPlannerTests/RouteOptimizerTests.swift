import XCTest
import CoreLocation
@testable import TripPlanner

final class RouteOptimizerTests: XCTestCase {
    private func points(_ latitudes: [Double]) -> [CLLocationCoordinate2D] {
        latitudes.map { CLLocationCoordinate2D(latitude: $0, longitude: 0) }
    }

    func testOrdersAlongALine() {
        // Stops on a north-south line in scrambled order; start at index 0.
        let order = RouteOptimizer.order(points([0.0, 0.3, 0.1, 0.2]))
        XCTAssertEqual(order, [0, 2, 3, 1])
    }

    func testKeepsFirstStopFirst() {
        let order = RouteOptimizer.order(points([0.5, 0.0, 0.2, 0.4, 0.1]))
        XCTAssertEqual(order.first, 0)
        XCTAssertEqual(Set(order), Set(0..<5))
    }

    func testNeverLongerThanOriginal() {
        let original = points([0.0, 0.9, 0.1, 0.8, 0.2, 0.7])
        let order = RouteOptimizer.order(original)
        let optimized = RouteOptimizer.length(order.map { original[$0] })
        XCTAssertLessThanOrEqual(optimized, RouteOptimizer.length(original))
    }

    func testTinyRoutesAreUnchanged() {
        XCTAssertEqual(RouteOptimizer.order(points([0.0, 1.0])), [0, 1])
        XCTAssertEqual(RouteOptimizer.order([]), [])
    }
}
