import Foundation

/// The answers of the Auto plan questionnaire. Saved on the trip so the flow is pre-filled next time.
struct TripPreferences: Codable, Equatable {
    enum Group: String, Codable, CaseIterable, Identifiable {
        case solo, couple, friends, family, group
        var id: String { rawValue }

        var title: String {
            switch self {
            case .solo: "Solo"
            case .couple: "Couple"
            case .friends: "Friends"
            case .family: "Family with kids"
            case .group: "Bigger group"
            }
        }

        var detail: String {
            switch self {
            case .solo: "Just me, my pace"
            case .couple: "Romantic or relaxed for two"
            case .friends: "A trip with mates"
            case .family: "Kid-friendly, earlier evenings"
            case .group: "Club, team or extended family"
            }
        }

        var symbol: String {
            switch self {
            case .solo: "person.fill"
            case .couple: "heart.fill"
            case .friends: "person.2.fill"
            case .family: "figure.2.and.child.holdinghands"
            case .group: "person.3.fill"
            }
        }

        var defaultTravelers: Int {
            switch self {
            case .solo: 1
            case .couple: 2
            case .friends: 4
            case .family: 4
            case .group: 8
            }
        }
    }

    enum Pace: String, Codable, CaseIterable, Identifiable {
        case relaxed, balanced, packed
        var id: String { rawValue }

        var title: String {
            switch self {
            case .relaxed: "Relaxed"
            case .balanced: "Balanced"
            case .packed: "Packed"
            }
        }

        var detail: String {
            switch self {
            case .relaxed: "About 4 stops a day, lots of time"
            case .balanced: "About 6 stops a day"
            case .packed: "8 stops a day, see everything"
            }
        }

        var symbol: String {
            switch self {
            case .relaxed: "tortoise.fill"
            case .balanced: "figure.walk"
            case .packed: "hare.fill"
            }
        }

        /// Sights and activities per day, not counting meals, café and nightlife.
        var activitiesPerDay: Int {
            switch self {
            case .relaxed: 2
            case .balanced: 3
            case .packed: 5
            }
        }
    }

    enum DayStart: String, Codable, CaseIterable, Identifiable {
        case early, normal, late
        var id: String { rawValue }

        var title: String {
            switch self {
            case .early: "Early (8:00)"
            case .normal: "Normal (9:30)"
            case .late: "Late (11:00)"
            }
        }

        var minutes: Int {
            switch self {
            case .early: 8 * 60
            case .normal: 9 * 60 + 30
            case .late: 11 * 60
            }
        }
    }

    enum Interest: String, Codable, CaseIterable, Identifiable {
        case sights, museums, food, cafes, nature, beaches, shopping, nightlife, family, adventure, hiddenGems
        var id: String { rawValue }

        var title: String {
            switch self {
            case .sights: "Sights & landmarks"
            case .museums: "Museums & art"
            case .food: "Food & restaurants"
            case .cafes: "Cafés & bakeries"
            case .nature: "Nature & parks"
            case .beaches: "Beaches"
            case .shopping: "Shopping & markets"
            case .nightlife: "Nightlife & bars"
            case .family: "Family activities"
            case .adventure: "Adventure & sports"
            case .hiddenGems: "Hidden gems"
            }
        }

        var symbol: String {
            switch self {
            case .sights: "building.columns.fill"
            case .museums: "paintpalette.fill"
            case .food: "fork.knife"
            case .cafes: "cup.and.saucer.fill"
            case .nature: "leaf.fill"
            case .beaches: "beach.umbrella.fill"
            case .shopping: "bag.fill"
            case .nightlife: "moon.stars.fill"
            case .family: "figure.and.child.holdinghands"
            case .adventure: "figure.hiking"
            case .hiddenGems: "sparkle.magnifyingglass"
            }
        }
    }

    enum Transport: String, Codable, CaseIterable, Identifiable {
        case walking, transit, car
        var id: String { rawValue }

        var title: String {
            switch self {
            case .walking: "Mostly on foot"
            case .transit: "Public transport"
            case .car: "Car"
            }
        }

        var detail: String {
            switch self {
            case .walking: "Compact days, short walks between stops"
            case .transit: "Spread out a bit more"
            case .car: "Day trips and distant spots are fine"
            }
        }

        var symbol: String {
            switch self {
            case .walking: "figure.walk"
            case .transit: "tram.fill"
            case .car: "car.fill"
            }
        }

        /// How far from the destination centre places are searched.
        var searchRadius: Double {
            switch self {
            case .walking: 5_000
            case .transit: 12_000
            case .car: 25_000
            }
        }

        /// Typical distance between two consecutive stops.
        var legScale: Double {
            switch self {
            case .walking: 1_500
            case .transit: 4_000
            case .car: 9_000
            }
        }
    }

    enum Budget: String, Codable, CaseIterable, Identifiable {
        case budget, midRange, treat
        var id: String { rawValue }

        var title: String {
            switch self {
            case .budget: "Budget"
            case .midRange: "Mid-range"
            case .treat: "Treat myself"
            }
        }

        var detail: String {
            switch self {
            case .budget: "Cheap eats, free sights first"
            case .midRange: "A good mix"
            case .treat: "Nicer restaurants and experiences"
            }
        }

        var symbol: String {
            switch self {
            case .budget: "eurosign.circle"
            case .midRange: "eurosign.circle.fill"
            case .treat: "sparkles"
            }
        }
    }

    enum NightlifeStyle: String, Codable, CaseIterable, Identifiable {
        case chill, lively, clubs
        var id: String { rawValue }

        var title: String {
            switch self {
            case .chill: "Chill bars"
            case .lively: "Lively bars & pubs"
            case .clubs: "Clubs & dancing"
            }
        }

        var symbol: String {
            switch self {
            case .chill: "wineglass.fill"
            case .lively: "mug.fill"
            case .clubs: "music.note.house.fill"
            }
        }

        var searchQuery: String {
            switch self {
            case .chill: "cocktail bar"
            case .lively: "bar pub"
            case .clubs: "nightclub"
            }
        }
    }

    var group: Group = .couple
    var travelers = 2
    var days = 3
    var pace: Pace = .balanced
    var dayStart: DayStart = .normal
    var interests: Set<Interest> = [.sights, .food]
    var includeLunch = true
    var includeDinner = true
    var cuisines: Set<String> = []
    var vegetarian = false
    var nightlifeStyle: NightlifeStyle = .lively
    var nightEndHour = 23
    var transport: Transport = .walking
    var budget: Budget = .midRange
    var mustSeeNames: [String] = []

    var isFamily: Bool { group == .family }
    var wantsNightlife: Bool { interests.contains(.nightlife) && !isFamily }
    var wantsCafes: Bool { interests.contains(.cafes) }
    var wantsMeals: Bool { includeLunch || includeDinner }

    /// Kinds of places used for the sightseeing slots of each day.
    var activityKinds: [DiscoverKind] {
        var kinds: [DiscoverKind] = []
        func add(_ kind: DiscoverKind) {
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        if interests.contains(.sights) { add(.sights) }
        if interests.contains(.museums) { add(.culture) }
        if interests.contains(.nature) || interests.contains(.beaches) { add(.nature) }
        if interests.contains(.shopping) { add(.shopping) }
        if interests.contains(.family) || interests.contains(.adventure) || isFamily { add(.fun) }
        if kinds.isEmpty { add(.sights) }
        return kinds
    }

    /// Everything that has to be searched for.
    var neededKinds: [DiscoverKind] {
        var kinds = activityKinds
        if wantsMeals || interests.contains(.food) { kinds.append(.food) }
        if wantsCafes { kinds.append(.cafe) }
        if wantsNightlife { kinds.append(.nightlife) }
        return kinds
    }

    /// Time the day has to be over.
    var endLimitMinutes: Int {
        if isFamily { return 19 * 60 + 30 }
        return wantsNightlife ? nightEndHour * 60 : 21 * 60 + 30
    }
}
