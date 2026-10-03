import Foundation

/// Exchange rates from open.er-api.com (free, no key). The last result is kept so the budget
/// still works offline.
actor CurrencyService {
    static let shared = CurrencyService()

    private struct Response: Decodable {
        let result: String
        let rates: [String: Double]
    }

    private var memory: [String: [String: Double]] = [:]

    /// Rates relative to `base`: `rates["USD"]` is how many USD one unit of `base` buys.
    func rates(base: String) async -> [String: Double]? {
        if let cached = memory[base] { return cached }

        if let url = URL(string: "https://open.er-api.com/v6/latest/\(base)"),
           let response = try? await Net.get(Response.self, url: url),
           response.result == "success" {
            memory[base] = response.rates
            if let data = try? JSONEncoder().encode(response.rates) {
                UserDefaults.standard.set(data, forKey: "rates-\(base)")
            }
            return response.rates
        }

        if let data = UserDefaults.standard.data(forKey: "rates-\(base)"),
           let stored = try? JSONDecoder().decode([String: Double].self, from: data) {
            memory[base] = stored
            return stored
        }
        return nil
    }

    /// Converts `amount` from `code` into the base the rates were loaded for. Nil if unknown.
    static func convert(_ amount: Double, from code: String, base: String, rates: [String: Double]?) -> Double? {
        if code == base { return amount }
        guard let rate = rates?[code], rate > 0 else { return nil }
        return amount / rate
    }
}
