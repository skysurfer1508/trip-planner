import SwiftUI
import SwiftData
import MapKit

struct BookingEditView: View {
    let trip: Trip
    let kind: BookingKind
    let booking: Booking?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(Secrets.self) private var secrets

    private enum LookupState {
        case idle
        case loading
        case found(FlightLeg)
        case failed(String)
    }

    @State private var flightDate = Date()
    @State private var lookup: LookupState = .idle
    @State private var legs: [FlightLeg] = []
    @State private var bufferTouched = false
    @State private var loadedKey = ""
    @State private var showSettings = false

    @State private var title = ""
    @State private var otherEnd = ""
    @State private var placeName = ""
    @State private var address = ""
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var start = Date()
    @State private var end = Date()
    @State private var reference = ""
    @State private var notes = ""
    @State private var buffer = 120
    @State private var remind = true
    @State private var showPicker = false
    @State private var phone = ""
    @State private var website = ""

    private var placeLabel: String {
        kind == .hotel ? "Search for your hotel or address" : "Find the airport on the map"
    }

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .arrivalFlight, .departureFlight: flightFields
                case .hotel: hotelFields
                }

                Section {
                    Group {
                        Toggle("Remind me", isOn: $remind)
                        TextField("Booking reference (optional)", text: $reference)
                            .textInputAutocapitalization(.characters)
                        TextField("Notes", text: $notes, axis: .vertical)
                            .lineLimit(1...4)
                    }
                    .listRowBackground(Theme.surface)
                } footer: {
                    Text(reminderHint)
                }

                if let booking {
                    Section {
                        Group {
                            Button("Delete", role: .destructive) {
                                context.delete(booking)
                                dismiss()
                            }
                        }
                        .listRowBackground(Theme.surface)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(booking == nil ? "Add \(kind.shortTitle.lowercased())" : "Edit \(kind.shortTitle.lowercased())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(kind == .hotel && title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
            .task(id: lookupKey) {
                // Looks the flight up by itself once the number and date are complete. An existing
                // booking is left alone until its number or date is changed.
                guard kind != .hotel, secrets.hasAerodatabox,
                      FlightLookupService.normalize(title) != nil,
                      lookupKey != loadedKey else { return }
                try? await Task.sleep(for: .milliseconds(800))
                if Task.isCancelled { return }
                await runLookup()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showPicker) {
                if kind == .hotel {
                    HotelSearchView(trip: trip, initialQuery: title) { hotel in
                        title = hotel.name
                        placeName = hotel.name
                        address = hotel.address
                        coordinate = hotel.coordinate
                        phone = hotel.phone ?? ""
                        website = hotel.website ?? ""
                    }
                } else {
                    PlacePickerView(query: "airport \(trip.destination)", region: trip.searchRegion) { item in
                        placeName = item.name ?? placeName
                        address = item.placemark.title ?? ""
                        coordinate = item.placemark.coordinate
                    }
                }
            }
        }
    }

    // MARK: Fields

    @ViewBuilder
    private var flightFields: some View {
        Section {
            TextField("Flight number (e.g. LH 1234)", text: $title)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            if let airline = AirlineDirectory.name(forFlightNumber: title) {
                Label(airline, systemImage: "airplane")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }
            DatePicker("Flight date", selection: $flightDate, displayedComponents: .date)
            lookupStatus
        } header: {
            Text("Flight")
        } footer: {
            Text(secrets.hasAerodatabox
                 ? "Type the flight number and date; the airports and times are filled in for you. You can still change anything."
                 : "Add a free flight data key in Settings and the airports and times are filled in from the flight number.")
        }

        Section {
            TextField(kind == .arrivalFlight ? "Flying from (city or airport)" : "Flying to (city or airport)",
                      text: $otherEnd)
            if kind == .arrivalFlight {
                DatePicker("Lands", selection: $end, displayedComponents: [.date, .hourAndMinute])
            } else {
                DatePicker("Takes off", selection: $start, displayedComponents: [.date, .hourAndMinute])
            }
        } footer: {
            Text("Use the local time printed on the ticket.")
        }

        Section {
            placeButton
            Stepper(kind == .arrivalFlight
                    ? "After landing: \(Format.minutes(buffer))"
                    : "Before take-off: \(Format.minutes(buffer))",
                    value: Binding(get: { buffer }, set: { buffer = $0; bufferTouched = true }),
                    in: 30...360, step: 15)
        } footer: {
            Text(kind == .arrivalFlight
                 ? "Time to get off the plane, through the airport and to the hotel. The first day starts after it."
                 : "Time to get to the airport, check in and pass security. The last day ends in time for it.")
        }
    }

    @ViewBuilder
    private var hotelFields: some View {
        Section {
            TextField("Hotel name", text: $title)
            placeButton
            if !address.isEmpty {
                Label(address, systemImage: "mappin.and.ellipse")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }
            if !phone.isEmpty, let url = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) {
                Link(destination: url) {
                    Label(phone, systemImage: "phone.fill")
                }
            }
            if !website.isEmpty, let url = URL(string: website) {
                Link(destination: url) {
                    Label("Hotel website", systemImage: "safari")
                }
            }
            DatePicker("Check-in", selection: $start, displayedComponents: [.date, .hourAndMinute])
            DatePicker("Check-out", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
        }
    }

    private var placeButton: some View {
        Button {
            showPicker = true
        } label: {
            HStack {
                Label(placeName.isEmpty ? placeLabel : placeName,
                      systemImage: coordinate == nil ? "mappin.and.ellipse" : "mappin.circle.fill")
                Spacer()
                if coordinate != nil {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.success)
                }
            }
        }
    }

    @ViewBuilder
    private var lookupStatus: some View {
        switch lookup {
        case .idle:
            if !secrets.hasAerodatabox && FlightLookupService.normalize(title) != nil {
                Button {
                    showSettings = true
                } label: {
                    Label("Add a flight data key to look this up", systemImage: "key.fill")
                }
            } else if secrets.hasAerodatabox {
                Button {
                    Task { await runLookup() }
                } label: {
                    Label("Look up flight", systemImage: "magnifyingglass")
                }
                .disabled(FlightLookupService.normalize(title) == nil)
            }
        case .loading:
            HStack(spacing: Spacing.m) {
                ProgressView()
                Text("Looking up the flight…")
                    .foregroundStyle(Theme.inkSecondary)
            }
        case .found(let leg):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label("\(leg.from.iata ?? leg.from.name) → \(leg.to.iata ?? leg.to.name)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                Text("\(Format.time(leg.departure)) → \(Format.time(leg.arrival))\(leg.status.map { " · \($0)" } ?? "")")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }
            if legs.count > 1 {
                Picker("Which leg?", selection: Binding(get: { leg.id }, set: { id in
                    if let chosen = legs.first(where: { $0.id == id }) {
                        Task { await apply(chosen) }
                    }
                })) {
                    ForEach(legs) { option in
                        Text("\(option.from.iata ?? option.from.name) → \(option.to.iata ?? option.to.name)").tag(option.id)
                    }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Spacing.s) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
                Button("Try again") { Task { await runLookup() } }
                    .font(.footnote)
            }
        }
    }

    private var lookupKey: String {
        let number = FlightLookupService.normalize(title) ?? ""
        let day = flightDate.formatted(.iso8601.year().month().day())
        return "\(number)|\(day)|\(secrets.hasAerodatabox)"
    }

    private func runLookup() async {
        guard kind != .hotel else { return }
        guard let number = FlightLookupService.normalize(title) else {
            lookup = .failed(FlightLookupError.invalidNumber.localizedDescription)
            return
        }
        guard secrets.hasAerodatabox else {
            lookup = .failed(FlightLookupError.noKey.localizedDescription)
            return
        }
        lookup = .loading
        do {
            let found = try await FlightLookupService.lookup(number: number, date: flightDate, key: secrets.keys.aerodatabox)
            legs = found
            guard let best = FlightLookupService.bestLeg(found, kind: kind, near: trip.destinationCoordinate) else {
                throw FlightLookupError.notFound
            }
            await apply(best)
        } catch {
            if Task.isCancelled { return }
            lookup = .failed(error.localizedDescription)
        }
    }

    /// Fills the form from a found leg: times, the airport at the destination, the other end.
    private func apply(_ leg: FlightLeg) async {
        var airport = kind == .arrivalFlight ? leg.to : leg.from
        let other = kind == .arrivalFlight ? leg.from : leg.to
        if airport.coordinate == nil {
            airport.coordinate = await FlightLookupService.coordinate(for: airport)
        }

        start = leg.departure
        end = leg.arrival
        placeName = airport.displayName
        address = airport.city ?? ""
        coordinate = airport.coordinate
        otherEnd = other.shortName
        if !bufferTouched {
            buffer = FlightLookupService.defaultBuffer(kind: kind, leg: leg)
        }
        let terminal = kind == .arrivalFlight ? leg.arrivalTerminal : leg.departureTerminal
        if notes.isEmpty, let terminal, !terminal.isEmpty {
            notes = "Terminal \(terminal)"
        }
        lookup = .found(leg)
    }

    private var reminderHint: String {
        switch kind {
        case .arrivalFlight: "No reminder is needed for landing."
        case .departureFlight: "You get a note the evening before and another when it's time to leave for the airport."
        case .hotel: "You get a reminder an hour before check-out."
        }
    }

    // MARK: Load and save

    private func load() {
        let calendar = Calendar.current
        func at(_ date: Date, _ hour: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
        }

        if let booking {
            title = booking.title
            otherEnd = booking.otherEnd
            placeName = booking.placeName
            address = booking.address
            coordinate = booking.coordinate
            start = booking.startDate
            end = booking.endDate
            reference = booking.reference
            notes = booking.notes
            buffer = booking.bufferMinutes
            remind = booking.remind
            phone = booking.phone
            website = booking.website
            flightDate = booking.kind == .arrivalFlight ? booking.endDate : booking.startDate
            bufferTouched = true
            loadedKey = lookupKey
            return
        }

        switch kind {
        case .arrivalFlight:
            end = at(trip.startDate, 12)
            start = end.addingTimeInterval(-2 * 3600)
            buffer = 120
            flightDate = trip.startDate
        case .departureFlight:
            start = at(trip.endDate, 15)
            end = start.addingTimeInterval(2 * 3600)
            buffer = 180
            flightDate = trip.endDate
        case .hotel:
            start = at(trip.startDate, 15)
            end = at(trip.endDate, 11)
            buffer = 0
        }
    }

    private func save() async {
        let target = booking ?? Booking(kind: kind, startDate: start, endDate: end)
        if booking == nil {
            context.insert(target)
            target.trip = trip
        }
        target.title = title.trimmingCharacters(in: .whitespaces)
        target.otherEnd = otherEnd.trimmingCharacters(in: .whitespaces)
        target.placeName = placeName
        target.address = address
        target.startDate = start
        target.endDate = end
        target.reference = reference
        target.notes = notes
        target.bufferMinutes = buffer
        target.remind = remind
        target.phone = phone
        target.website = website
        if let coordinate {
            target.latitude = coordinate.latitude
            target.longitude = coordinate.longitude
            target.hasCoordinate = true
        } else {
            target.hasCoordinate = false
        }

        if remind, kind != .arrivalFlight {
            _ = await NudgeService.requestAuthorization()
        }
        await NudgeService.rescheduleBookingReminders(trip.bookings.map(\.info))
        dismiss()
    }
}
