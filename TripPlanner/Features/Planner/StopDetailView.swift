import SwiftUI

struct StopDetailView: View {
    @Bindable var stop: Stop
    @Environment(\.dismiss) private var dismiss

    private static let defaultHour = 9

    private var hasTime: Binding<Bool> {
        Binding(
            get: { stop.plannedTime != nil },
            set: { on in
                if on {
                    let base = stop.day?.date ?? Date()
                    stop.plannedTime = Calendar.current.date(bySettingHour: Self.defaultHour, minute: 0, second: 0, of: base)
                } else {
                    stop.plannedTime = nil
                }
            }
        )
    }

    private var time: Binding<Date> {
        Binding(
            get: { stop.plannedTime ?? Date() },
            set: { newValue in
                stop.plannedTime = stop.day?.combine(time: newValue) ?? newValue
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $stop.name)
                    Picker("Category", selection: $stop.category) {
                        ForEach(StopCategory.allCases) { category in
                            Label(category.title, systemImage: category.symbol).tag(category)
                        }
                    }
                    if !stop.address.isEmpty {
                        Label(stop.address, systemImage: "mappin.and.ellipse")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !stop.phone.isEmpty,
                       let url = URL(string: "tel:" + stop.phone.filter { $0.isNumber || $0 == "+" }) {
                        Link(destination: url) {
                            Label(stop.phone, systemImage: "phone.fill")
                        }
                    }
                    if !stop.website.isEmpty, let url = URL(string: stop.website) {
                        Link(destination: url) {
                            Label("Website", systemImage: "safari")
                        }
                    }
                }

                Section("Schedule") {
                    Toggle("Planned time", isOn: hasTime)
                    if stop.plannedTime != nil {
                        DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                    }
                    Stepper("Stay: \(Format.minutes(stop.durationMinutes))",
                            value: $stop.durationMinutes, in: 15...600, step: 15)
                    Toggle("Done", isOn: $stop.isDone)
                }

                Section("Budget") {
                    HStack {
                        Text("Estimated cost")
                        Spacer()
                        TextField("0", value: $stop.estimatedCost, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                        Text(stop.day?.trip?.currencyCode ?? "")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Notes") {
                    TextField("Tickets, tips, reservation number…", text: $stop.notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    Button("Directions in Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill") {
                        RoutingService.openInMaps(name: stop.name, coordinate: stop.coordinate, mode: .walk)
                    }
                }
            }
            .navigationTitle("Stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
