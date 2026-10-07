import Foundation
import CoreLocation

/// Decoder for encoded polylines (Google format). Transitous uses precision 6, others 5.
enum Polyline {
    static func decode(_ encoded: String, precision: Int = 5) -> [CLLocationCoordinate2D] {
        let factor = pow(10.0, Double(precision))
        let bytes = Array(encoded.utf8)
        var index = 0
        var latitude = 0
        var longitude = 0
        var result: [CLLocationCoordinate2D] = []

        func nextValue() -> Int? {
            var value = 0
            var shift = 0
            while index < bytes.count {
                let byte = Int(bytes[index]) - 63
                index += 1
                value |= (byte & 0x1f) << shift
                shift += 5
                if byte < 0x20 {
                    return (value & 1) != 0 ? ~(value >> 1) : (value >> 1)
                }
            }
            return nil
        }

        while index < bytes.count {
            guard let dLat = nextValue(), let dLon = nextValue() else { break }
            latitude += dLat
            longitude += dLon
            result.append(CLLocationCoordinate2D(latitude: Double(latitude) / factor,
                                                 longitude: Double(longitude) / factor))
        }
        return result
    }
}
