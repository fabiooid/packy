import SwiftUI

struct WorkloadView: View {
    @Environment(AppModel.self) private var model
    @State private var opened: PackModel?
    @State private var openError: String?
    @State private var opening = false
    @State private var didResumeOnLaunch = false
    @State private var pendingNext: WorkloadOrder?
    @State private var cancelling: WorkloadOrder?
    @State private var tab: ListTab = .toPack
    @State private var query = ""

    enum ListTab { case toPack, packed }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    header
                    if let workload = model.workload, workload.fixture { FixtureBanner() }
                    // One notice at a time for the connection: an order that did not open is the same problem.
                    if case .failed(let message) = model.loadState {
                        Notice(title: PackingFlow.serverUnreachable, detail: message, icon: "wifi.exclamationmark")
                    } else if let openError {
                        Notice(title: openError)
                    }
                    if let workload = model.workload {
                        tabs(workload)
                        searchField
                        switch tab {
                        case .toPack: content(workload)
                        case .packed: packedList
                        }
                    } else if case .loading = model.loadState {
                        ProgressView("Carico gli ordini…").padding(.top, 40)
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
                Text("L'ordine torna tra quelli da imballare. Svuota la scatola.")
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
            Spacer(minLength: 8)
            Button {
                Task { await model.refresh() }
            } label: {
                Group {
                    if refreshing {
                        ProgressView().tint(Theme.accent)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .frame(width: 44, height: 44)
                .background(Theme.accentSoft, in: Circle())
                .contentShape(Circle())
            }
            .disabled(refreshing)
            .accessibilityLabel(refreshing ? "Aggiornamento in corso" : "Aggiorna ordini")
            Menu {
                Button("Esci dall'account", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    Task { await model.logout() }
                }
            } label: {
                Circle().fill(Theme.ink).frame(width: 44, height: 44)
                    .overlay(Image(systemName: "person.fill").foregroundStyle(.white))
            }
            .accessibilityLabel("Account")
        }
        .padding(.top, 12)
    }

    private var refreshing: Bool {
        if case .loading = model.loadState { return true }
        return false
    }

    @ViewBuilder private func content(_ workload: Workload) -> some View {
        let active = model.activeOwnedOrder()
        let upNext = PackingFlow.packableOrders(workload.orders)
            .filter { $0.id != active?.id && PackingFlow.matches(query, recipient: $0.recipient, reference: $0.reference) }
        let sourceFailed = PackingFlow.orderSourceFailed(workload.sources)

        // The empty state says the same thing, so the notice shows only above a list.
        if sourceFailed && !upNext.isEmpty {
            Notice(title: "Una fonte non risponde", detail: "Potrebbero mancare ordini.", icon: "wifi.exclamationmark")
        }

        if let active { continueCard(active) }

        VStack(spacing: 8) {
            SectionLabel(active == nil ? "Ordini da imballare" : "Prossimi")
            if upNext.isEmpty {
                VStack(spacing: 10) {
                    // An emoji only when the list is truly empty: that is good news. A failed source keeps the plain icon.
                    Group {
                        if !query.isEmpty {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(Theme.secondary)
                        } else if sourceFailed {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(Theme.danger)
                        } else {
                            Text("☕️").font(.system(size: 34))
                        }
                    }
                    .accessibilityHidden(true)
                    Text(!query.isEmpty ? "Nessun ordine trovato." : sourceFailed ? PackingFlow.sourceFailed : PackingFlow.emptyOrders)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 28)
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

    private func tabs(_ workload: Workload) -> some View {
        let toPack = PackingFlow.packableOrders(workload.orders).count
        return HStack(spacing: 4) {
            tabButton("Da imballare", count: toPack, value: .toPack)
            tabButton("Imballati", count: model.packed.count, value: .packed)
        }
        .padding(4)
        .background(Color(hex: 0xE9E7E1), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .contain)
    }

    private func tabButton(_ title: String, count: Int, value: ListTab) -> some View {
        let on = tab == value
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { tab = value }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(on ? Theme.accentSoft : Theme.track, in: Capsule())
                    .foregroundStyle(on ? Theme.accent : Theme.secondary)
            }
            .foregroundStyle(on ? Theme.ink : Theme.secondary)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(on ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: on ? .black.opacity(0.1) : .clear, radius: 2, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
            TextField("", text: $query, prompt: Text("Cerca cliente o numero ordine").foregroundStyle(Theme.secondary))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .foregroundStyle(Theme.ink)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.track)
                }
                .accessibilityLabel("Cancella ricerca")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .card(radius: 12)
    }

    @ViewBuilder private var packedList: some View {
        let found = model.packed.filter { PackingFlow.matches(query, recipient: $0.recipient, reference: $0.reference) }
        if found.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: query.isEmpty ? "shippingbox" : "magnifyingglass")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .accessibilityHidden(true)
                Text(query.isEmpty ? "Nessun ordine imballato negli ultimi 30 giorni." : "Nessun ordine trovato.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 28)
            .card()
        } else {
            ForEach(PackingFlow.packedGroups(found), id: \.label) { group in
                VStack(spacing: 8) {
                    SectionLabel(group.label)
                    VStack(spacing: 0) {
                        ForEach(Array(group.orders.enumerated()), id: \.element.id) { index, order in
                            PackedRow(order: order)
                            if index < group.orders.count - 1 { Divider().overlay(Theme.divider).padding(.leading, 16) }
                        }
                    }
                    .card()
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
                openError = "Server non raggiungibile. Ordine non aperto."
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

private struct PackedRow: View {
    let order: PackedOrder

    var body: some View {
        // No check mark per row: everything in this tab is packed.
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(order.recipient ?? "Cliente senza nome").font(.headline).foregroundStyle(Theme.ink)
                Text("\(order.reference) · \(order.units) \(PackingFlow.unitWord(order.units)) · \(order.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "it_IT")))) · \(order.completedByName)")
                    .font(.footnote).foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                if let short = order.shortUnits, short > 0 {
                    Chip(text: "Parziale · \(short) da spedire", foreground: Theme.warning, background: Theme.warningSoft)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Imballato. \(order.recipient ?? "Cliente senza nome"), \(order.reference), \(order.units) \(PackingFlow.unitWord(order.units)), da \(order.completedByName)")
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
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.track)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}
