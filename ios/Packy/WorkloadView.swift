import SwiftUI

struct WorkloadView: View {
    @Environment(AppModel.self) private var model
    @State private var opened: PackModel?
    @State private var openError: String?
    @State private var opening = false
    @State private var clearedNotice: String?
    @State private var didClearOnLaunch = false

    var body: some View {
        NavigationStack {
            List {
                if let workload = model.workload, workload.fixture {
                    Section { FixtureBanner() }
                }
                if let clearedNotice {
                    Section {
                        Label(clearedNotice, systemImage: "arrow.uturn.backward.circle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
                if case .failed(let message) = model.loadState {
                    Section { Label(message, systemImage: "wifi.exclamationmark").foregroundStyle(.red) }
                }
                if let openError {
                    Section { Text(openError).foregroundStyle(.red) }
                }
                if let workload = model.workload {
                    orderSections(workload)
                    Section("Sources") {
                        ForEach(workload.sources) { SourceRow(source: $0) }
                    }
                } else if case .loading = model.loadState {
                    Section { ProgressView("Checking orders...") }
                }
            }
            .navigationTitle("Orders")
            .refreshable { await model.refresh() }
            .toolbar {
                Menu {
                    Button("Sign out") { Task { await model.logout() } }
                } label: {
                    Image(systemName: "person.circle")
                }
                .accessibilityLabel("Account")
            }
            .navigationDestination(item: $opened) { PackScreen(model: $0) }
            .onChange(of: opened) { previous, current in
                guard current == nil, let previous else { return }
                Task {
                    if previous.pack.status == "active", previous.pack.isOwner, !previous.didRelease {
                        if await previous.emptyBox() == false {
                            openError = "This order is still open. It was not cleared."
                        }
                    }
                    await model.refresh()
                }
            }
        }
        .task {
            if model.workload == nil { await model.refresh() }
            guard !didClearOnLaunch else { return }
            didClearOnLaunch = true
            if let reference = await model.clearUnfinishedOrderAfterColdStart() {
                clearedNotice = "Packy was closed, so \(reference) was cleared. If items are still in the box, put them back."
            }
        }
    }

    private func activeOrder() -> WorkloadOrder? {
        model.workload?.orders.first { $0.packStatus == "active" && $0.isOwner }
    }

    @ViewBuilder private func orderSections(_ workload: Workload) -> some View {
        let openNow = workload.orders.first { $0.packStatus == "active" && $0.isOwner }
        let toDo = workload.orders.filter { $0.packStatus != "completed" && ($0.eligible || $0.packId != nil) }
        let done = workload.orders.filter { $0.packStatus == "completed" }
        let notPackable = workload.orders.filter { !$0.eligible && $0.packId == nil }

        Section {
            if toDo.isEmpty {
                Text(emptyMessage(workload)).foregroundStyle(.secondary)
            }
            ForEach(toDo) { order in
                if openNow == nil || openNow?.id == order.id {
                    Button { open(order) } label: { OrderRow(order: order) }.foregroundStyle(.primary)
                } else {
                    OrderRow(order: order, locked: true)
                }
            }
        } header: {
            Text("To do")
        } footer: {
            if openNow != nil {
                Text("One order at a time. Finish it, or stop and put the items back, before starting another.")
            }
        }
        if !done.isEmpty {
            Section {
                ForEach(done) { order in
                    if openNow == nil {
                        Button { open(order) } label: { OrderRow(order: order) }.foregroundStyle(.primary)
                    } else {
                        OrderRow(order: order, locked: true)
                    }
                }
            } header: {
                Text("Done")
            } footer: {
                Text("Done means the box was checked. It does not ship the order.")
            }
        }
        if !notPackable.isEmpty {
            Section("Cannot pack") {
                ForEach(notPackable) { order in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(order.reference).font(.headline)
                        Text(order.ineligibleReason ?? "Not eligible").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Says "no orders" only when every connected source actually answered.
    private func emptyMessage(_ workload: Workload) -> String {
        let orderSources = workload.sources.filter { $0.name != "fic" }
        let failed = orderSources.filter { $0.status == "unavailable" }.map(\.displayName)
        if !failed.isEmpty { return "Could not check \(failed.joined(separator: ", ")). There may be orders you cannot see." }
        if !orderSources.contains(where: { $0.status == "ok" }) { return "No order source is connected, so orders are unknown." }
        return "No orders to do."
    }

    private func open(_ order: WorkloadOrder) {
        if let current = activeOrder(), current.id != order.id {
            openError = "Finish \(current.reference) first. One order at a time."
            open(current)
            return
        }
        guard opened == nil, !opening else { return }
        opening = true
        openError = nil
        clearedNotice = nil
        Task {
            defer { opening = false }
            do {
                let pack: Pack = try await model.api.send("POST", "v1/packs", body: ["source": order.source, "orderId": order.orderId])
                opened = PackModel(pack: pack, api: model.api) { model.signOutLocally() }
            } catch APIFailure.signedOut {
                model.signOutLocally()
            } catch APIFailure.rejected(_, let message, _) {
                openError = message
            } catch {
                openError = "Could not reach the server, so this order was not opened."
            }
        }
    }
}

extension PackModel: Hashable {
    nonisolated static func == (lhs: PackModel, rhs: PackModel) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

struct FixtureBanner: View {
    var body: some View {
        Label("Fixture data. These are not real orders.", systemImage: "testtube.2")
            .font(.subheadline.bold())
            .foregroundStyle(.orange)
    }
}

private struct OrderRow: View {
    let order: WorkloadOrder
    var locked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(order.reference).font(.headline)
                Spacer()
                Text(order.packStatus == "completed" ? "Done" : "To do")
                    .font(.subheadline.bold())
                    .foregroundStyle(order.packStatus == "completed" ? .green : .secondary)
            }
            if let recipient = order.recipient {
                Text(recipient).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(notes, id: \.0) { note in
                Label(note.0, systemImage: note.1).font(.footnote).foregroundStyle(note.2)
            }
        }
        .padding(.vertical, 2)
    }

    private var notes: [(String, String, Color)] {
        var result: [(String, String, Color)] = []
        if order.changedAfterCompletion { result.append(("This order changed after it was marked done", "exclamationmark.triangle.fill", .red)) }
        if !order.eligible { result.append((order.ineligibleReason ?? "Cannot pack", "xmark.octagon.fill", .red)) }
        if order.blockedLines > 0 { result.append(("\(order.blockedLines) item(s) cannot be checked yet", "exclamationmark.triangle.fill", .orange)) }
        if locked { result.append(("Finish the open order first", "lock.fill", .secondary)) }
        if order.packStatus == "active", !order.isOwner { result.append(("Open on another phone", "eye", .secondary)) }
        if order.freshness.state != "current" { result.append(("Saved copy, not current", "clock.badge.exclamationmark", .orange)) }
        return result
    }
}

private struct SourceRow: View {
    let source: SourceState

    var body: some View {
        HStack {
            Text(source.displayName)
            Spacer()
            Text(label).foregroundStyle(color).font(.subheadline)
        }
    }

    private var label: String {
        switch source.status {
        case "ok": "Connected"
        case "unavailable": "Unavailable"
        default: "Not connected"
        }
    }

    private var color: Color {
        switch source.status {
        case "ok": .green
        case "unavailable": .red
        default: .secondary
        }
    }
}
