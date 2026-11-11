import SwiftUI

struct WorkloadView: View {
    @Environment(AppModel.self) private var model
    @State private var opened: PackModel?
    @State private var openError: String?
    @State private var opening = false
    @State private var didResumeOnLaunch = false

    var body: some View {
        NavigationStack {
            List {
                if let workload = model.workload, workload.fixture {
                    Section { FixtureBanner() }
                }
                if case .failed(let message) = model.loadState {
                    Section { Label(message, systemImage: "wifi.exclamationmark").foregroundStyle(.red) }
                }
                if let openError {
                    Section { Text(openError).foregroundStyle(.red) }
                }
                if let workload = model.workload {
                    orderSection(workload)
                } else if case .loading = model.loadState {
                    Section { ProgressView("Checking orders...") }
                }
            }
            .navigationTitle(PackingFlow.listHeading)
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
                Task { await handleLeave(previous) }
            }
        }
        .task {
            if model.workload == nil { await model.refresh() }
            guard !didResumeOnLaunch else { return }
            didResumeOnLaunch = true
            resumeActiveSession()
        }
    }

    @ViewBuilder private func orderSection(_ workload: Workload) -> some View {
        let orders = PackingFlow.packableOrders(workload.orders)
        let sourceFailed = PackingFlow.orderSourceFailed(workload.sources)

        Section {
            if sourceFailed {
                Text(PackingFlow.sourceFailed).foregroundStyle(.secondary)
            }
            if orders.isEmpty {
                if !sourceFailed {
                    Text(PackingFlow.emptyListMessage(sourceFailed: sourceFailed)).foregroundStyle(.secondary)
                }
            } else {
                ForEach(orders) { order in
                    Button { open(order) } label: { OrderRow(order: order) }.foregroundStyle(.primary)
                }
            }
        } footer: {
            Text(PackingFlow.listPurpose)
        }
    }

    private func resumeActiveSession() {
        guard opened == nil, let order = model.activeOwnedOrder() else { return }
        open(order)
    }

    /// If the operator leaves after a count, put them back on the same session.
    /// If nothing was counted, the order stays ready to pack.
    private func handleLeave(_ previous: PackModel) async {
        if previous.didRelease || previous.pack.status != "active" {
            await model.refresh()
            return
        }
        if PackingFlow.sessionLocked(status: previous.pack.status, isOwner: previous.pack.isOwner, hasRecordedCount: previous.pack.hasRecordedCount) {
            opened = previous
            return
        }
        if previous.pack.isOwner && previous.pack.canLeave && !previous.didRelease {
            _ = await previous.emptyBox()
        }
        await model.refresh()
        if opened == nil { resumeActiveSession() }
    }

    private func open(_ order: WorkloadOrder) {
        if let current = model.activeOwnedOrder(), current.id != order.id {
            open(current)
            return
        }
        guard opened == nil, !opening else { return }
        opening = true
        openError = nil
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
        Label(PackingFlow.sampleMode, systemImage: "testtube.2")
            .font(.subheadline.bold())
            .foregroundStyle(.orange)
    }
}

private struct OrderRow: View {
    let order: WorkloadOrder

    var body: some View {
        HStack {
            Text(order.reference).font(.headline)
            Spacer()
            Text(PackingFlow.startAction)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
