import SwiftUI
import SwiftData

/// Flights and hotels. The app uses them to know when you arrive, where you sleep and when you
/// have to leave.
struct BookingsView: View {
    @Bindable var trip: Trip

    @Environment(\.modelContext) private var context
    @State private var editing: BookingEditTarget?
    @State private var message: String?

    struct BookingEditTarget: Identifiable {
        let id = UUID()
        let kind: BookingKind
        let booking: Booking?
    }

    private func bookings(_ kind: BookingKind) -> [Booking] {
        trip.bookings.filter { $0.kind == kind }.sorted { $0.keyDate < $1.keyDate }
    }

    var body: some View {
        List {
            section(.arrivalFlight, footer: "When you land, the first day starts after a buffer for the airport and the way to the hotel.")
            section(.hotel, footer: "The hotel is where each day starts from. Check-in and check-out times show on those days.")
            section(.departureFlight, footer: "On the day you fly home, the plan ends in time to get to the airport.")

            if !trip.bookings.isEmpty {
                Section {
                    Button {
                        let result = BookingPlanner.addStops(for: trip)
                        message = result.added == 0
                            ? (result.skippedWithoutLocation > 0
                               ? "Pick the airport or hotel on the map so the stops have a location."
                               : "Everything is already on the plan.")
                            : "Added \(result.added) \(result.added == 1 ? "stop" : "stops") to the plan."
                    } label: {
                        Label("Add them to the plan", systemImage: "calendar.badge.plus")
                    }
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Adds landing, check-in, check-out, leaving for the airport and take-off as stops on the right days and times.")
                }
            }
        }
        .navigationTitle("Flights & hotel")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { target in
            BookingEditView(trip: trip, kind: target.kind, booking: target.booking)
        }
        .onChange(of: trip.bookings.count) {
            Task { await NudgeService.rescheduleBookingReminders(trip.bookings.map(\.info)) }
        }
    }

    private func section(_ kind: BookingKind, footer: String) -> some View {
        Section {
            ForEach(bookings(kind)) { booking in
                Button {
                    editing = BookingEditTarget(kind: kind, booking: booking)
                } label: {
                    BookingRow(booking: booking)
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                let list = bookings(kind)
                for index in offsets {
                    context.delete(list[index])
                }
            }
            Button {
                editing = BookingEditTarget(kind: kind, booking: nil)
            } label: {
                Label("Add \(kind == .hotel ? "a hotel" : kind == .arrivalFlight ? "your arrival flight" : "your flight home")",
                      systemImage: "plus.circle.fill")
            }
        } header: {
            Label(kind.title, systemImage: kind.symbol)
        } footer: {
            Text(footer)
        }
    }
}

struct BookingRow: View {
    let booking: Booking

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: booking.kind.symbol)
                .font(.title3)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: Radius.shape(Radius.small))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(booking.title.isEmpty ? booking.kind.shortTitle : booking.title)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !booking.placeName.isEmpty {
                    Text(booking.placeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        func stamp(_ date: Date) -> String {
            date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        }
        switch booking.kind {
        case .arrivalFlight: return "Lands \(stamp(booking.endDate))" + (booking.otherEnd.isEmpty ? "" : " · from \(booking.otherEnd)")
        case .departureFlight: return "Takes off \(stamp(booking.startDate))" + (booking.otherEnd.isEmpty ? "" : " · to \(booking.otherEnd)")
        case .hotel: return "\(stamp(booking.startDate)) → \(stamp(booking.endDate))"
        }
    }
}
