import SwiftUI
import SwiftData
import MapKit

struct BookingEditView: View {
    let trip: Trip
    let kind: BookingKind
    let booking: Booking?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

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

    private var placeLabel: String {
        kind == .hotel ? "Find the hotel on the map" : "Find the airport on the map"
    }

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .arrivalFlight, .departureFlight: flightFields
                case .hotel: hotelFields
                }

                Section {
                    Toggle("Remind me", isOn: $remind)
                    TextField("Booking reference (optional)", text: $reference)
                        .textInputAutocapitalization(.characters)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                } footer: {
                    Text(reminderHint)
                }

                if let booking {
                    Section {
                        Button("Delete", role: .destructive) {
                            context.delete(booking)
                            dismiss()
                        }
                    }
                }
            }
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
            .sheet(isPresented: $showPicker) {
                PlacePickerView(query: kind == .hotel ? "hotel \(trip.destination)" : "airport \(trip.destination)",
                                region: trip.searchRegion) { item in
                    placeName = item.name ?? placeName
                    address = item.placemark.title ?? ""
                    coordinate = item.placemark.coordinate
                    if kind == .hotel && title.trimmingCharacters(in: .whitespaces).isEmpty {
                        title = item.name ?? ""
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
                    value: $buffer, in: 30...360, step: 15)
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
                        .foregroundStyle(.green)
                }
            }
        }
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
            return
        }

        switch kind {
        case .arrivalFlight:
            end = at(trip.startDate, 12)
            start = end.addingTimeInterval(-2 * 3600)
            buffer = 120
        case .departureFlight:
            start = at(trip.endDate, 15)
            end = start.addingTimeInterval(2 * 3600)
            buffer = 180
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
