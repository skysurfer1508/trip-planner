import Foundation

struct PackingOptions {
    enum Climate: String, CaseIterable, Identifiable {
        case warm, mild, cold
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var climate: Climate = .mild
    var nights = 3
    var rain = false
    var beach = false
    var hiking = false
    var business = false
    var nightlife = false
    var kids = false
}

/// Starter checklists. Everything can be edited afterwards.
enum PackingTemplates {
    static let beforeYouGo = "Before you go"

    static func items(for options: PackingOptions) -> [(section: String, title: String)] {
        var items: [(String, String)] = []
        func add(_ section: String, _ titles: [String]) {
            items.append(contentsOf: titles.map { (section, $0) })
        }

        add("Documents & money", [
            "Passport / ID", "Entry documents or visa", "Travel insurance details",
            "Tickets and bookings (saved offline)", "Debit / credit cards", "Some local cash",
        ])

        let days = min(max(options.nights + 1, 2), 8)
        var clothes = ["Underwear (\(days))", "Socks (\(days))", "T-shirts / tops (\(days))",
                       "Trousers or skirts", "Comfortable walking shoes", "Pyjamas"]
        switch options.climate {
        case .warm:
            clothes += ["Shorts", "Light dress or shirts", "Sunglasses", "Sun hat"]
        case .mild:
            clothes += ["Light jacket", "Sweater"]
        case .cold:
            clothes += ["Warm jacket", "Sweaters", "Thermal underwear", "Gloves", "Scarf and hat"]
        }
        if options.rain { clothes += ["Rain jacket", "Umbrella"] }
        add("Clothes", clothes)

        var toiletries = ["Toothbrush and toothpaste", "Deodorant", "Shampoo and soap",
                          "Personal medication", "Plasters / first aid", "Hand sanitizer"]
        if options.climate == .warm || options.beach { toiletries.append("Sunscreen") }
        add("Toiletries & health", toiletries)

        add("Electronics", ["Phone charger", "Power bank", "Plug adapter", "Headphones"])

        var gear: [String] = []
        if options.beach { gear += ["Swimwear", "Beach towel", "Flip-flops"] }
        if options.hiking { gear += ["Hiking boots", "Daypack", "Water bottle", "Rain shell"] }
        if options.business { gear += ["Business outfit", "Laptop and charger"] }
        if options.nightlife { gear += ["Smart outfit for evenings"] }
        if options.kids { gear += ["Snacks", "Games or books for the journey", "Kids' essentials"] }
        if !gear.isEmpty { add("Activities", gear) }

        add(beforeYouGo, [
            "Check passport validity", "Book accommodation", "Book transport",
            "Check entry requirements", "Tell your bank you're travelling",
            "Download offline maps (Apple Maps)", "Check in online", "Arrange plant or pet care",
        ])
        return items
    }
}
