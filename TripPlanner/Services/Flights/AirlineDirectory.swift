import Foundation

/// Airline names for the two-character IATA code at the start of a flight number, so the app can
/// say "Lufthansa" as soon as you type "LH 1234", even without internet.
enum AirlineDirectory {
    private static let names: [String: String] = [
        "LH": "Lufthansa", "LX": "Swiss", "OS": "Austrian", "EW": "Eurowings", "SN": "Brussels Airlines",
        "KL": "KLM", "AF": "Air France", "BA": "British Airways", "IB": "Iberia", "VY": "Vueling",
        "TP": "TAP Air Portugal", "AZ": "ITA Airways", "SK": "SAS", "AY": "Finnair", "DY": "Norwegian",
        "TK": "Turkish Airlines", "PC": "Pegasus", "XQ": "SunExpress", "DE": "Condor", "FR": "Ryanair",
        "U2": "easyJet", "W6": "Wizz Air", "HV": "Transavia", "TO": "Transavia France", "V7": "Volotea",
        "UX": "Air Europa", "EI": "Aer Lingus", "FI": "Icelandair", "LO": "LOT Polish", "OK": "Czech Airlines",
        "A3": "Aegean", "BT": "airBaltic", "JU": "Air Serbia", "OU": "Croatia Airlines", "RO": "TAROM",
        "EK": "Emirates", "QR": "Qatar Airways", "EY": "Etihad", "SV": "Saudia", "GF": "Gulf Air",
        "WY": "Oman Air", "RJ": "Royal Jordanian", "MS": "EgyptAir", "ET": "Ethiopian", "KQ": "Kenya Airways",
        "SA": "South African", "AT": "Royal Air Maroc", "SU": "Aeroflot",
        "AA": "American", "DL": "Delta", "UA": "United", "AC": "Air Canada", "WN": "Southwest",
        "B6": "JetBlue", "AS": "Alaska", "NK": "Spirit", "F9": "Frontier", "HA": "Hawaiian", "WS": "WestJet",
        "AM": "Aeroméxico", "CM": "Copa", "AV": "Avianca", "LA": "LATAM", "G3": "Gol", "AD": "Azul",
        "QF": "Qantas", "NZ": "Air New Zealand", "VA": "Virgin Australia", "VS": "Virgin Atlantic",
        "SQ": "Singapore Airlines", "CX": "Cathay Pacific", "NH": "ANA", "JL": "Japan Airlines",
        "KE": "Korean Air", "OZ": "Asiana", "TG": "Thai Airways", "MH": "Malaysia Airlines",
        "GA": "Garuda Indonesia", "VN": "Vietnam Airlines", "PR": "Philippine Airlines", "AI": "Air India",
        "6E": "IndiGo", "CA": "Air China", "MU": "China Eastern", "CZ": "China Southern", "BR": "EVA Air",
        "CI": "China Airlines", "AK": "AirAsia", "FZ": "flydubai", "G9": "Air Arabia", "J2": "Azerbaijan Airlines",
    ]

    /// "LH 1234" -> "Lufthansa"
    static func name(forFlightNumber number: String) -> String? {
        guard let normalized = FlightLookupService.normalize(number) else { return nil }
        return names[String(normalized.prefix(2))]
    }
}
