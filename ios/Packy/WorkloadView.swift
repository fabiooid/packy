import SwiftUI

struct WorkloadView: View {
    @Environment(AppModel.self) private var model
    @State private var opened: PackModel?
    @State private var openError: String?
    @State private var opening = false
    @State private var didResumeOnLaunch = false
    @State private var pendingNext: WorkloadOrder?
    @State private var cancelling: WorkloadOrder?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if let workload = model.workload, workload.fixture { FixtureBanner() }
                    if case .failed(let message) = model.loadState {
                        problem(message, icon: "wifi.exclamationmark")
                    }
                    if let openError { problem(openError, icon: "exclamationmark.circle.fill") }
                    if let workload = model.workload {
                        content(workload)
                    } else if case .loading = model.loadState {
                        ProgressView("Controllo ordini...").padding(.top, 40)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .background(Theme.ground.ignoresSafeArea())
            .refreshable { await model.refresh() }
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog("Cancellare \(cancelling?.reference ?? "l'ordine")?", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }), titleVisibility: .visible, presenting: cancelling) { order in
                Button("Cancella e svuota la scatola", role: .destructive) {
                    Task { openError = await model.cancel(order) }
                }
            } message: { _ in
                Text("I conteggi tornano a 0 e l'ordine torna tra quelli da imballare. Togli tutto dalla scatola.")
            }
            .navigationDestination(item: $opened) { pack in
                PackScreen(model: pack) { next in
                    pendingNext = next
                    opened = nil
                }
            }
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

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.secondary)
                Text(PackingFlow.listHeading).font(Theme.display(34)).foregroundStyle(Theme.ink)
            }
            Spacer()
            Menu {
                Button("Aggiorna ordini") { Task { await model.refresh() } }
                Button("Esci dall'account", role: .destructive) { Task { await model.logout() } }
            } label: {
                Circle().fill(Theme.ink).frame(width: 44, height: 44)
                    .overlay(Image(systemName: "person.fill").foregroundStyle(.white))
            }
            .accessibilityLabel("Account")
        }
        .padding(.top, 12)
    }

    @ViewBuilder private func content(_ workload: Workload) -> some View {
        let active = model.activeOwnedOrder()
        let upNext = PackingFlow.packableOrders(workload.orders).filter { $0.id != active?.id }
        let sourceFailed = PackingFlow.orderSourceFailed(workload.sources)

        if sourceFailed { problem(PackingFlow.sourceFailed, icon: "wifi.exclamationmark") }

        if let active { continueCard(active) }

        VStack(spacing: 8) {
            SectionLabel(active == nil ? "Ordini da imballare" : "Prossimi")
            if upNext.isEmpty {
                Text(sourceFailed ? PackingFlow.sourceFailed : PackingFlow.emptyOrders)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .card()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(upNext.enumerated()), id: \.element.id) { index, order in
                        Button { open(order) } label: { OrderRow(order: order) }
                            .buttonStyle(.plain)
                            .disabled(active != nil)
                        if index < upNext.count - 1 { Divider().overlay(Theme.divider).padding(.leading, 16) }
                    }
                }
                .card()
                .opacity(active == nil ? 1 : 0.55)
                if let active {
                    Text("Prima finisci \(active.reference).")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                }
            }
        }
    }

    private func continueCard(_ order: WorkloadOrder) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("IN CORSO").font(.caption.weight(.semibold)).tracking(0.6).opacity(0.85)
                Spacer()
                Button { cancelling = order } label: {
                    Label("Cancella", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(.white.opacity(0.18), in: Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancella l'ordine in corso")
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(order.reference).font(Theme.display(28))
                    if let customer = order.recipient { Text(customer).font(.headline).opacity(0.9) }
                }
                Spacer()
                Text("\(order.verified) di \(order.units)").font(Theme.display(20, .semibold))
            }
            ProgressBar(done: order.verified, total: order.units, color: .white, empty: .white.opacity(0.3), height: 6)
            Button { open(order) } label: {
                Label("Riprendi", systemImage: "arrow.right")
                    .labelStyle(TrailingIconLabel())
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 24))
    }

    private func problem(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 16))
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
            openPendingNext()
            return
        }
        if PackingFlow.sessionLocked(status: previous.pack.status, isOwner: previous.pack.isOwner, hasRecordedCount: previous.pack.hasRecordedCount) {
            // Exiting keeps the progress. The order stays "In corso" and the others stay locked until it is done.
            await model.refresh()
            return
        }
        if previous.pack.isOwner && previous.pack.canLeave && !previous.didRelease {
            _ = await previous.emptyBox()
        }
        await model.refresh()
        if opened == nil { resumeActiveSession() }
    }

    private func openPendingNext() {
        guard let next = pendingNext else { return }
        pendingNext = nil
        if let fresh = model.workload?.orders.first(where: { $0.id == next.id }), fresh.eligible, fresh.packStatus == nil {
            open(fresh)
        }
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
                openError = "Server non raggiungibile: l'ordine non è stato aperto."
            }
        }
    }
}

extension PackModel: Hashable {
    nonisolated static func == (lhs: PackModel, rhs: PackModel) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.title; configuration.icon }
    }
}

private struct OrderRow: View {
    let order: WorkloadOrder

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(order.recipient ?? "Cliente senza nome").font(.headline).foregroundStyle(Theme.ink)
                Text("\(order.reference) · \(order.units) \(PackingFlow.unitWord(order.units))")
                    .font(.footnote).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color(hex: 0x8A8D94))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}
