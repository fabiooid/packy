import SwiftUI

struct PackScreen: View {
    @Bindable var model: PackModel
    var onStartNext: (WorkloadOrder) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var confirmingRestart = false
    @State private var markingShort: Line?

    private var pack: Pack { model.pack }
    private var ownsActive: Bool { pack.status == "active" && pack.isOwner }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.ground.ignoresSafeArea()
            Group {
                if pack.status == "completed" {
                    PackedView(model: model, onStartNext: onStartNext, onBack: { dismiss() })
                } else if ownsActive && pack.canComplete {
                    ReadyView(model: model)
                } else {
                    packing
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: pack.status)
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Azzerare i conteggi di \(pack.reference)?", isPresented: $confirmingRestart, titleVisibility: .visible) {
            Button("Azzera e ricomincia", role: .destructive) {
                model.selectedLineId = nil
                Task { await model.perform("restart") }
            }
        } message: {
            Text("Svuota la scatola e scansiona di nuovo.")
        }
        .confirmationDialog(
            markingShort.map { PackingFlow.markShortQuestion($0) } ?? "",
            isPresented: Binding(get: { markingShort != nil }, set: { if !$0 { markingShort = nil } }),
            titleVisibility: .visible,
            presenting: markingShort
        ) { line in
            Button(PackingFlow.markShortAction(line)) {
                if model.selectedLineId == line.lineId { model.selectedLineId = nil }
                Task { await model.perform("lines/\(line.lineId)/short", extra: ["quantity": line.remaining]) }
            }
        } message: { _ in
            Text("L'ordine parte incompleto. I pezzi mancanti vanno spediti dopo.")
        }
    }

    private func clearShort(_ line: Line) {
        Task { await model.perform("lines/\(line.lineId)/short", extra: ["quantity": 0]) }
    }


    // MARK: Packing

    private var packing: some View {
        VStack(spacing: 0) {
            topBar
            cameraHeader
            ScrollView {
                VStack(spacing: 14) {
                    if pack.fixture { FixtureBanner() }
                    notices
                    StatusCard(model: model)
                    changes
                    openProblems
                    VStack(spacing: 10) {
                        if pack.canScan { SectionLabel("Prodotti") }
                        ForEach(pack.lines) { line in
                            LineCard(
                                line: line,
                                highlighted: line.lineId == selectedLine?.lineId,
                                onMarkShort: ownsActive && (line.canMarkShort ?? false) ? { markingShort = line } : nil,
                                onClearShort: ownsActive && line.shortCount > 0 ? { clearShort(line) } : nil
                            )
                                .opacity(canSelect(line) || line.lineId == selectedLine?.lineId ? 1 : 0.6)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard canSelect(line) else { return }
                                    model.selectedLineId = model.selectedLineId == line.lineId ? nil : line.lineId
                                    model.card = .idle
                                }
                                .accessibilityAddTraits(canSelect(line) ? [.isButton] : [])
                                .accessibilityHint(canSelect(line) ? "Scegli questo prodotto" : "")
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .refreshable { await model.refresh() }
            footer
        }
        .animation(.snappy(duration: 0.25), value: model.selectedLineId)
    }

    /// Navigation lives on the light background, outside the camera card.
    private var topBar: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(pack.recipient ?? pack.reference).font(Theme.display(17, .semibold)).foregroundStyle(Theme.ink)
                if pack.recipient != nil {
                    Text(pack.reference).font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 96)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            topBarButtons
        }
        .padding(.horizontal, 16)
    }

    private var topBarButtons: some View {
        HStack {
            Button { dismiss() } label: {
                Label("Ordini", systemImage: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Esci dall'ordine")
            Spacer()
            if ownsActive && pack.hasRecordedCount {
                Button { confirmingRestart = true } label: {
                    Label("Azzera", systemImage: "arrow.counterclockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.danger)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    private var cameraHeader: some View {
        VStack(spacing: 12) {
            if pack.canScan, let line = selectedLine, PackingFlow.needsScan(line) {
                countCard(line, enabled: PackingFlow.canConfirmFromHeader(line: line, pendingScan: pendingScan)) {
                    ScannerPanel { code, symbology in model.handleRead(code, symbology: symbology) }
                        .id(line.lineId)
                } action: {
                    guard let scan = pendingScan else { return }
                    Task { await model.confirm(scan) }
                }
            } else if pack.canScan, let line = selectedLine {
                countCard(line, enabled: PackingFlow.canConfirmFromHeader(line: line, pendingScan: nil)) {
                    VStack(spacing: 10) {
                        Image(systemName: line.shipping ? "shippingbox" : "eye").font(.system(size: 30, weight: .medium))
                        Text(line.shipping ? "Metti l'etichetta giusta" : line.custom ? "Custom: controlla a vista" : "Controlla a vista").font(.headline)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 18))
                } action: {
                    Task { await model.confirmManual(line) }
                }
            } else if pack.canScan {
                VStack(spacing: 10) {
                    Image(systemName: "hand.tap").font(.system(size: 30, weight: .medium))
                    Text("Scegli un prodotto").font(.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 200)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 18))
            } else {
                Label(cameraOffReason, systemImage: "camera.badge.ellipsis")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, minHeight: 72)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .background(Theme.night, in: RoundedRectangle(cornerRadius: 28))
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    /// One layout for every count, scanned or by hand: the product, a panel, then Aggiungi.
    /// The frame and the button turn green together when the count is ready to add.
    private func countCard<Panel: View>(_ line: Line, enabled: Bool, @ViewBuilder panel: () -> Panel, action: @escaping () -> Void) -> some View {
        let rejected: Bool = { if case .rejected = model.card { return true } else { return false } }()
        let frame: Color? = rejected ? Theme.danger : (enabled ? Theme.success : nil)
        return VStack(spacing: 14) {
            Text(scanTitle(line)).font(.headline).foregroundStyle(.white).lineLimit(1)
            panel()
                .frame(height: 200)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(frame ?? .clear, lineWidth: 3))
                .animation(.easeOut(duration: 0.2), value: frame)
            if case .rejected(let scan) = model.card {
                wrongRead(scan)
            }
            Button(action: action) {
                Label(PackingFlow.countAction, systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle(color: Theme.success, height: 54, onDark: true))
            .disabled(model.busy || !enabled)
            .padding(.horizontal, 8)
        }
    }

    private func headerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(.white.opacity(0.14), in: Capsule())
    }

    private func wrongRead(_ scan: Scan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(scan.outcome == "wrong_product" ? "Prodotto sbagliato" : "Non contato", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text(scan.outcome == "wrong_product" ? "Non contato" : scan.message)
                .font(.subheadline.weight(.medium))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.danger)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    private var pendingScan: Scan? {
        guard case .offer(let scan) = model.card else { return nil }
        return scan
    }

    private var selectedLine: Line? {
        guard let id = model.selectedLineId else { return nil }
        return pack.lines.first { $0.lineId == id && $0.state != "done" && $0.state != "blocked" }
    }

    private func scanTitle(_ line: Line) -> String {
        let parts = PackingFlow.splitSize(line.identity.ficName ?? line.identity.sourceTitle)
        return [parts.name, parts.size].compactMap { $0 }.joined(separator: " · ")
    }

    private func canSelect(_ line: Line) -> Bool {
        pack.canScan && line.state != "done" && line.state != "blocked"
    }

    private var cameraOffReason: String {
        if !pack.isOwner { return "Aperto su un altro telefono. Puoi solo guardare." }
        if !pack.eligible { return pack.ineligibleReason ?? "Questo ordine non si può imballare." }
        if !pack.changes.isEmpty { return "Fotocamera in pausa. L'ordine è cambiato." }
        return "Fotocamera in pausa."
    }

    @ViewBuilder private var notices: some View {
        if let message = pack.freshness.message {
            HStack(spacing: 10) {
                Label(message, systemImage: "clock.badge.exclamationmark").font(.subheadline).foregroundStyle(Theme.warning)
                Spacer()
                Button("Aggiorna") { Task { await model.refresh() } }.font(.subheadline.weight(.semibold))
            }
            .padding(14)
            .background(Theme.warningSoft, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var totalUnits: Int { PackingFlow.pieces(pack.lines).total }
    private var countedUnits: Int { PackingFlow.pieces(pack.lines).counted }

    /// The order count stays pinned under the list, so it is in view while scrolling products.
    private var footer: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(countedUnits) di \(totalUnits)").font(Theme.display(24)).foregroundStyle(Theme.ink)
                Text("nella scatola").font(.subheadline.weight(.medium)).foregroundStyle(Theme.secondary)
                Spacer()
            }
            ProgressBar(done: countedUnits, total: totalUnits)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Theme.ground.overlay(alignment: .top) { Divider().overlay(Theme.border) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(countedUnits) di \(totalUnits) nella scatola")
    }

    @ViewBuilder private var changes: some View {
        if !pack.changes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("L'ordine è cambiato", systemImage: "arrow.triangle.2.circlepath").font(.headline).foregroundStyle(Theme.warning)
                ForEach(pack.changes) { Text($0.message).font(.subheadline).foregroundStyle(Theme.body) }
                if ownsActive {
                    Button("Usa l'ordine aggiornato") { Task { await model.perform("reconcile") } }
                        .buttonStyle(PrimaryButtonStyle(color: Theme.warning, height: 50))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .card(border: Theme.warning, width: 2)
        }
    }

    @ViewBuilder private var openProblems: some View {
        ForEach(pack.discrepancies) { item in
            VStack(alignment: .leading, spacing: 10) {
                Text(item.title).font(.headline).foregroundStyle(Theme.danger)
                Text(item.detail).font(.subheadline).foregroundStyle(Theme.body)
                if ownsActive { ResolutionButtons(item: item, model: model) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .card(border: Theme.danger, width: 2)
        }
    }

}

// MARK: - Inline status

private struct StatusCard: View {
    let model: PackModel

    var body: some View {
        switch model.card {
        case .idle, .offer, .rejected:
            EmptyView()
        case .checking(let code):
            HStack(spacing: 10) {
                ProgressView()
                Text("Controllo \(code)…").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.body)
                Spacer()
            }
            .padding(14)
            .card()
        case .recorded(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(Theme.success)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .card(border: Theme.success, width: 2)
        case .notRecorded(let message), .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 20))
        case .unknownResult(let scan, let actionId):
            VStack(alignment: .leading, spacing: 10) {
                Label("Nessuna risposta dal server. Riprova: il pezzo non viene contato due volte.", systemImage: "wifi.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.danger)
                Button("Riprova") { Task { await model.confirm(scan, actionId: actionId) } }
                    .buttonStyle(PrimaryButtonStyle(height: 50))
            }
            .padding(16)
            .background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

// MARK: - Line card

struct LineCard: View {
    let line: Line
    var highlighted = false
    /// Out of stock: offered by long-press on any card, and by the "⋯" button on the selected one.
    var onMarkShort: (() -> Void)?
    var onClearShort: (() -> Void)?

    var body: some View {
        let parts = PackingFlow.splitSize(line.identity.ficName ?? line.identity.sourceTitle)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(parts.name).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if highlighted && hasActions {
                        Menu { actions } label: {
                            Image(systemName: "ellipsis")
                                .font(.body.weight(.bold))
                                .foregroundStyle(Theme.secondary)
                                .frame(width: 36, height: 28)
                                .background(Theme.divider, in: Capsule())
                        }
                        .accessibilityLabel("Altre azioni")
                    }
                }
                HStack(spacing: 10) {
                    if let size = parts.size { SizeBadge(size: size, strong: highlighted || line.state != "done") }
                    if let codice = line.identity.codice {
                        Text(codice).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Theme.secondary)
                    }
                    if line.shipping {
                        Chip(text: "Spedizione", foreground: Theme.secondary, background: Theme.divider)
                    } else if line.custom {
                        Chip(text: "Custom · conferma a mano", foreground: Theme.warning, background: Theme.warningSoft)
                    } else if line.verification?.method == "manual" {
                        Chip(text: "Senza codice", foreground: Theme.warning, background: Theme.warningSoft)
                    }
                }
                if line.shortCount > 0 {
                    Chip(text: PackingFlow.shortStatus(line) + " · da spedire dopo", foreground: Theme.warning, background: Theme.warningSoft)
                }
            }
            ForEach(reasons, id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Theme.warning)
            }
            if highlighted, PackingFlow.needsScan(line) {
                Label("In scansione", systemImage: "barcode.viewfinder")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            HStack(spacing: 12) {
                ProgressBar(done: line.verified, total: line.required, height: 6)
                HStack(spacing: 6) {
                    if line.state == "done" {
                        Image(systemName: line.shortCount > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(line.shortCount > 0 ? Theme.warning : Theme.success)
                    }
                    Text(PackingFlow.countLabel(verified: line.verified, required: line.required))
                        .font(Theme.display(20))
                        .foregroundStyle(line.state == "done" ? (line.shortCount > 0 ? Theme.warning : Theme.success) : Theme.ink)
                }
                .fixedSize()
            }
            if line.uncertain > 0 {
                Label("\(line.uncertain) da riscansionare", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(Theme.warning)
            }
        }
        .padding(16)
        .card(border: borderColor, width: highlighted ? 2 : 1)
        .contextMenu { if hasActions { actions } }
    }

    private var hasActions: Bool { onMarkShort != nil || onClearShort != nil }

    @ViewBuilder private var actions: some View {
        if let onMarkShort {
            Button(PackingFlow.markShortAction(line), systemImage: "shippingbox.and.arrow.backward", action: onMarkShort)
        }
        if let onClearShort {
            Button("Annulla esauriti", systemImage: "arrow.uturn.backward", action: onClearShort)
        }
    }

    private var reasons: [String] {
        [line.kind == "uncertain" ? line.kindReason : nil, line.identity.reason, line.verification?.reason].compactMap { $0 }
    }

    private var borderColor: Color {
        if highlighted { return Theme.accent }
        switch line.state {
        case "done": return line.shortCount > 0 ? Theme.warning : Theme.success
        case "blocked", "recheck": return Theme.warning
        default: return Theme.border
        }
    }
}

struct ResolutionButtons: View {
    let item: Discrepancy
    let model: PackModel

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(item.resolutions.enumerated()), id: \.element) { index, resolution in
                Button(Self.label(for: resolution)) {
                    Task { await model.perform("discrepancies/\(item.id)/resolve", extra: ["resolution": resolution]) }
                }
                .buttonStyle(ResolutionStyle(primary: index == 0))
                .disabled(model.busy)
            }
        }
    }

    static func label(for resolution: String) -> String {
        switch resolution {
        case "set_aside": "Tolto dalla scatola"
        case "never_in_box": "Mai messo nella scatola"
        case "repeat_read": "Letto due volte"
        default: resolution
        }
    }
}

private struct ResolutionStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(primary ? .white : Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(primary ? Theme.ink : Theme.divider, in: RoundedRectangle(cornerRadius: 16))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Ready

private struct ReadyView: View {
    let model: PackModel

    private var pack: Pack { model.pack }
    private var total: Int { PackingFlow.pieces(pack.lines).total }
    private var counted: Int { PackingFlow.pieces(pack.lines).counted }
    private var short: Int { PackingFlow.shortTotal(pack.lines) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 2) {
                    Text(pack.recipient ?? pack.reference).font(Theme.display(18, .semibold)).foregroundStyle(Theme.ink)
                    if pack.recipient != nil { Text(pack.reference).font(.caption).foregroundStyle(Theme.secondary) }
                }
                if pack.fixture { FixtureBanner() }
                ZStack {
                    Circle().stroke(Theme.track, lineWidth: 10)
                    Circle().trim(from: 0, to: total > 0 ? CGFloat(counted) / CGFloat(total) : 1)
                        .stroke(short > 0 ? Theme.warning : Theme.success, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(counted)/\(total)").font(Theme.display(38))
                        Text(PackingFlow.unitWord(total)).font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                .frame(width: 132, height: 132)
                .accessibilityElement(children: .combine)
                Text(short > 0 ? "Spedizione parziale" : "Tutto nella scatola").font(Theme.display(28)).foregroundStyle(Theme.ink)
                if short > 0 {
                    Notice(title: "\(PackingFlow.shortLabel(short)): da spedire dopo", detail: "Il pacco parte senza questi pezzi.",
                           icon: "shippingbox.and.arrow.backward", color: Theme.warning, soft: Theme.warningSoft)
                }

                VStack(spacing: 0) {
                    ForEach(Array(pack.lines.enumerated()), id: \.element.lineId) { index, line in
                        // Two columns only: the product and its count. The size sits on the second line,
                        // so a long name can truncate without hiding which size it is.
                        let parts = PackingFlow.splitSize(line.identity.ficName ?? line.identity.sourceTitle)
                        let codice = line.identity.codice ?? ""
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(parts.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                    .lineLimit(1).truncationMode(.tail)
                                if parts.size != nil || !codice.isEmpty || line.shortCount > 0 {
                                    HStack(spacing: 8) {
                                        if let size = parts.size {
                                            Text(size).font(.footnote.weight(.bold)).foregroundStyle(.white)
                                                .padding(.horizontal, 7).padding(.vertical, 2)
                                                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 6))
                                                .fixedSize()
                                        }
                                        (Text(line.shortCount > 0 && !codice.isEmpty ? "\(codice) · " : codice).foregroundStyle(Theme.secondary)
                                         + Text(line.shortCount > 0 ? PackingFlow.shortBadge(line) : "").fontWeight(.semibold).foregroundStyle(Theme.warning))
                                            .font(.footnote)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            Spacer(minLength: 8)
                            Text(PackingFlow.countLabel(verified: line.verified, required: line.required))
                                .font(Theme.display(17))
                                .foregroundStyle(line.shortCount > 0 ? Theme.warning : Theme.ink)
                                .fixedSize()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        if index < pack.lines.count - 1 { Divider().overlay(Theme.divider) }
                    }
                }
                .card()


                if case .recorded = model.card {} else { StatusCard(model: model) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                HoldToConfirm(title: "Tieni premuto per confermare", color: Theme.success) {
                    Task { await model.completeAfterRefresh() }
                }
                .disabled(model.busy)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.ground)
        }
    }
}

/// A deliberate press: the ring fills while held, so a brush of the thumb never marks an order packed.
struct HoldToConfirm: View {
    let title: String
    var color: Color = Theme.success
    var duration: Double = 1.0
    let action: () -> Void
    @State private var progress: CGFloat = 0
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(.white.opacity(0.35), lineWidth: 3)
                Circle().trim(from: 0, to: max(progress, 0.08)).stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 24, height: 24)
            Text(title).font(.headline)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(isEnabled ? color : Theme.track, in: RoundedRectangle(cornerRadius: 18))
        .scaleEffect(progress > 0 ? 0.98 : 1)
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 40) {
            progress = 0
            Feedback.recorded()
            action()
        } onPressingChanged: { pressing in
            withAnimation(pressing ? .linear(duration: duration) : .easeOut(duration: 0.2)) {
                progress = pressing ? 1 : 0
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

// MARK: - Packed

private struct PackedView: View {
    let model: PackModel
    let onStartNext: (WorkloadOrder) -> Void
    let onBack: () -> Void
    @Environment(AppModel.self) private var app

    private var pack: Pack { model.pack }
    private var units: Int { PackingFlow.pieces(pack.lines).counted }

    private var next: WorkloadOrder? {
        PackingFlow.packableOrders(app.workload?.orders ?? [])
            .first { $0.orderId != pack.orderId && $0.packStatus == nil }
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Circle().fill(Theme.success).frame(width: 96, height: 96)
                .overlay(Image(systemName: "checkmark").font(.system(size: 44, weight: .bold)).foregroundStyle(.white))
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                // The one celebratory moment in the flow. VoiceOver reads the word only.
                Text("Imballato 🎉").font(Theme.display(34)).foregroundStyle(Theme.ink)
                    .accessibilityLabel("Imballato")
                Text(pack.recipient ?? pack.reference).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                Text("\(pack.reference) · \(units) \(PackingFlow.unitWord(units))").font(.subheadline).foregroundStyle(Theme.secondary)
                if PackingFlow.shortTotal(pack.lines) > 0 {
                    Chip(text: "Parziale · \(PackingFlow.shortTotal(pack.lines)) da spedire", foreground: Theme.warning, background: Theme.warningSoft)
                        .padding(.top, 4)
                }
            }
            Spacer()
            VStack(spacing: 8) {
                if let next {
                    Button { onStartNext(next) } label: {
                        Label("Prossimo: \(next.recipient ?? next.reference)", systemImage: "arrow.right").labelStyle(TrailingIconLabel())
                    }
                    .buttonStyle(PrimaryButtonStyle(color: Theme.ink, height: 58))
                }
                Button("Torna agli ordini", action: onBack).buttonStyle(SecondaryButtonStyle(filled: next == nil))
                Text("Ora spediscilo come al solito.").font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .task { await app.refresh() }
    }
}

/// Keeps an open order from being left by the edge swipe. Leaving asks first.
private struct BackSwipeLock: UIViewControllerRepresentable {
    var locked: Bool

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        DispatchQueue.main.async {
            controller.navigationController?.interactivePopGestureRecognizer?.isEnabled = !locked
        }
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        controller.navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }
}
