import SwiftUI
import SwiftData

/// Flights and hotels. The app uses them to know when you arrive, where you sleep and when you
/// have to leave. Flights look like boarding passes, the hotel like a stay with check-in and check-out.
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
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                section(.arrivalFlight, footer: "When you land, the first day starts after a buffer for the airport and the way to the hotel.")
                section(.hotel, footer: "The hotel is where each day starts from. Check-in and check-out times show on those days.")
                section(.departureFlight, footer: "On the day you fly home, the plan ends in time to get to the airport.")

                if !trip.bookings.isEmpty {
                    addToPlan
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
        }
        .background(Theme.background)
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
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                Image(systemName: kind.symbol)
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(kind.title)
                    .font(Typography.title)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
            }

            ForEach(bookings(kind)) { booking in
                Button {
                    editing = BookingEditTarget(kind: kind, booking: booking)
                } label: {
                    if kind == .hotel {
                        HotelStayCard(booking: booking)
                    } else {
                        FlightPassCard(booking: booking)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit", systemImage: "pencil") {
                        editing = BookingEditTarget(kind: kind, booking: booking)
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Haptics.warning()
                        Motion.perform { context.delete(booking) }
                    }
                }
            }

            Button {
                editing = BookingEditTarget(kind: kind, booking: nil)
            } label: {
                Label("Add \(kind == .hotel ? "a hotel" : kind == .arrivalFlight ? "your arrival flight" : "your flight home")",
                      systemImage: "plus")
            }
            .buttonStyle(.secondary)

            Text(footer)
                .font(Typography.caption)
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    private var addToPlan: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Button {
                let result = BookingPlanner.addStops(for: trip)
                message = result.added == 0
                    ? (result.skippedWithoutLocation > 0
                       ? "Pick the airport or hotel on the map so the stops have a location."
                       : "Everything is already on the plan.")
                    : "Added \(result.added) \(result.added == 1 ? "stop" : "stops") to the plan."
                if result.added > 0 { Haptics.success() }
            } label: {
                Label("Add them to the plan", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.primary)

            if let message {
                Banner(kind: .info, title: message)
            }
            Text("Adds landing, check-in, check-out, leaving for the airport and take-off as stops on the right days and times.")
                .font(Typography.caption)
                .foregroundStyle(Theme.inkSecondary)
        }
    }
}

// MARK: - Flight

/// A flight as a boarding pass: where from, where to, when, and a perforated line before the details.
private struct FlightPassCard: View {
    let booking: Booking

    private var isArrival: Bool { booking.kind == .arrivalFlight }
    /// The airport on the trip's side is `placeName`, the other end is `otherEnd`.
    private var fromName: String { isArrival ? booking.otherEnd : booking.placeName }
    private var toName: String { isArrival ? booking.placeName : booking.otherEnd }

    private func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Spacing.m) {
                endpoint(label: "From", name: fromName, date: booking.startDate, alignment: .leading)
                Image(systemName: "airplane")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .padding(.top, Spacing.l)
                    .accessibilityHidden(true)
                endpoint(label: "To", name: toName, date: booking.endDate, alignment: .trailing)
            }
            .padding(Spacing.l)

            perforation

            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(booking.title.isEmpty ? booking.kind.shortTitle : booking.title)
                        .font(Typography.headline)
                        .foregroundStyle(Theme.ink)
                    Text(note)
                        .font(Typography.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: Spacing.s)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
            }
            .padding(Spacing.l)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .clipShape(Radius.shape(Radius.card))
        .overlay(Radius.shape(Radius.card).strokeBorder(Theme.separator, lineWidth: 0.5))
        .contentShape(Radius.shape(Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the booking to edit")
    }

    private func endpoint(label: String, name: String, date: Date, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: Spacing.xs) {
            Text(label).eyebrow()
            Text(name.isEmpty ? "–" : name)
                .font(Typography.label)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            Text(Format.time(date))
                .font(Typography.display)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(day(date))
                .font(Typography.caption)
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    /// The tear-off line: a dashed rule with a notch cut into each side of the card.
    private var perforation: some View {
        ZStack {
            Line()
                .stroke(Theme.separator, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .frame(height: 1.5)
                .padding(.horizontal, Spacing.l)
            HStack {
                Circle().fill(Theme.background).frame(width: 20, height: 20).offset(x: -10)
                Spacer()
                Circle().fill(Theme.background).frame(width: 20, height: 20).offset(x: 10)
            }
        }
        .frame(height: 20)
        .accessibilityHidden(true)
    }

    private var note: String {
        let stamp = { (date: Date) in date.formatted(.dateTime.hour().minute()) }
        if isArrival {
            let ready = booking.endDate.addingTimeInterval(TimeInterval(booking.bufferMinutes * 60))
            return "Day 1 can start around \(stamp(ready))"
        }
        let leave = booking.startDate.addingTimeInterval(-TimeInterval(booking.bufferMinutes * 60))
        return "Leave for the airport by \(stamp(leave))"
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// MARK: - Hotel

/// The hotel stay: check-in and check-out side by side, with the number of nights between them.
private struct HotelStayCard: View {
    let booking: Booking

    private var nights: Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: booking.startDate),
                                       to: calendar.startOfDay(for: booking.endDate)).day ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(booking.title.isEmpty ? booking.kind.shortTitle : booking.title)
                        .font(Typography.headline)
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                    if !booking.placeName.isEmpty {
                        Text(booking.placeName)
                            .font(Typography.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: Spacing.s)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
            }

            HStack(alignment: .top, spacing: Spacing.m) {
                stamp(label: "Check-in", date: booking.startDate)
                VStack(spacing: 2) {
                    Image(systemName: "bed.double.fill")
                        .foregroundStyle(Theme.accent)
                    Text("\(nights) \(nights == 1 ? "night" : "nights")")
                        .font(Typography.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .padding(.top, Spacing.m)
                .accessibilityHidden(true)
                stamp(label: "Check-out", date: booking.endDate)
            }
        }
        .card()
        .contentShape(Radius.shape(Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the booking to edit")
    }

    private func stamp(label: String, date: Date) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label).eyebrow()
            Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(Typography.label)
                .foregroundStyle(Theme.ink)
            Text(Format.time(date))
                .font(Typography.numeric)
                .foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
