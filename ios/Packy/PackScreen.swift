import SwiftUI

struct PackScreen: View {
    @Bindable var model: PackModel
    var onStartNext: (WorkloadOrder) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var confirmingRestart = false
    @State private var removing: Line?

    private var pack: Pack { model.pack }
    private var ownsActive: Bool { pack.status == "active" && pack.isOwner }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.ground.ignoresSafeArea()
            Group {
                if pack.status == "completed" {
                    PackedView(model: model, onStartNext: onStartNext, onBack: { dismiss() })
                } else if ownsActive && pack.canComplete && !sheetShown {
                    ReadyView(model: model)
                } else {
                    packing
                }
            }
            if sheetShown {
                Color.black.opacity(0.28).ignoresSafeArea().transition(.opacity)
                ScanSheet(model: model)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: sheetShown)
        .animation(.easeInOut(duration: 0.25), value: pack.status)
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Cancellare i conteggi di \(pack.reference)?", isPresented: $confirmingRestart, titleVisibility: .visible) {
            Button("Cancella e riparti da 0", role: .destructive) {
                model.selectedLineId = nil
                Task { await model.perform("restart") }
            }
        } message: {
            Text("Tutti i conteggi tornano a 0. Togli tutto dalla scatola, poi scansiona di nuovo.")
        }
        .confirmationDialog("Perché togli questo pezzo?", isPresented: removingShown, titleVisibility: .visible, presenting: removing) { line in
            ForEach([("damaged", "Danneggiato"), ("miscounted", "Contato per errore"), ("other", "Altro")], id: \.0) { reason in
                Button(reason.1) {
                    if let unit = line.units.last {
                        Task { await model.perform("units/\(unit.id)/remove", extra: ["reason": reason.0]) }
                    }
                }
            }
        } message: { _ in
            Text("Il conteggio viene tolto. Toglilo dalla scatola.")
        }
    }

    private var sheetShown: Bool {
        switch model.card {
        case .offer, .rejected: true
        default: false
        }
    }

    private var removingShown: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
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
                    progress
                    changes
                    openProblems
                    VStack(spacing: 10) {
                        if pack.canScan { SectionLabel("Scegli il prodotto da scansionare") }
                        ForEach(pack.lines) { line in
                            LineCard(line: line, highlighted: line.lineId == selectedLine?.lineId, canRemove: ownsActive) { removing = line }
                                .opacity(canSelect(line) || line.lineId == selectedLine?.lineId ? 1 : 0.6)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard canSelect(line) else { return }
                                    model.selectedLineId = model.selectedLineId == line.lineId ? nil : line.lineId
                                    model.card = .idle
                                }
                                .accessibilityAddTraits(canSelect(line) ? [.isButton] : [])
                                .accessibilityHint(canSelect(line) ? "Scegli questo prodotto da scansionare" : "")
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .refreshable { await model.refresh() }
            if ownsActive { footer }
        }
    }

    /// Navigation lives on the light background, outside the camera card.
    private var topBar: some View {
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
                    Label("Cancella", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.danger)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var cameraHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                VStack(spacing: 2) {
                    Text(pack.recipient ?? pack.reference).font(Theme.display(18, .semibold)).foregroundStyle(.white)
                    if pack.recipient != nil {
                        Text(pack.reference).font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 12)
            }
            if pack.canScan, let line = selectedLine {
                VStack(spacing: 2) {
                    Text("Scansiona").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                    Text(scanTitle(line)).font(.headline).foregroundStyle(.white).lineLimit(1)
                }
                ScannerPanel { code, symbology in model.handleRead(code, symbology: symbology) }
                    .frame(height: 200)
                    .id(line.lineId)
            } else if pack.canScan {
                VStack(spacing: 10) {
                    Image(systemName: "hand.tap").font(.system(size: 30, weight: .medium))
                    Text("Scegli un prodotto qui sotto").font(.headline)
                    Text("La fotocamera si accende quando scegli cosa scansionare.")
                        .font(.footnote).multilineTextAlignment(.center).opacity(0.75)
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

    private var totalUnits: Int { pack.lines.reduce(0) { $0 + $1.required } }
    private var countedUnits: Int { pack.lines.reduce(0) { $0 + $1.verified } }

    private var progress: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(countedUnits) di \(totalUnits) nella scatola").font(Theme.display(26)).foregroundStyle(Theme.ink)
                Spacer()
                let left = PackingFlow.unitsStillToDo(pack.lines)
                if left > 0 { Text("ne mancano \(left)").font(.subheadline).foregroundStyle(Theme.secondary) }
            }
            ProgressBar(done: countedUnits, total: totalUnits)
        }
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

    private var footer: some View {
        let left = PackingFlow.unitsStillToDo(pack.lines)
        let text = left > 0 ? "Scansiona ancora \(left) per finire" : "Non ancora pronto"
        return Button(text) {}
            .buttonStyle(PrimaryButtonStyle())
            .disabled(true)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Theme.ground.overlay(alignment: .top) { Divider().overlay(Theme.border) })
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
                Text("Letto \(code). Controllo...").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.body)
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
                Label("Nessuna risposta dal server. Questo pezzo potrebbe non essere contato.", systemImage: "wifi.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.danger)
                Button("Riprova (non può contare due volte)") { Task { await model.confirm(scan, actionId: actionId) } }
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
    var canRemove = false
    var onRemove: () -> Void = {}

    var body: some View {
        let parts = PackingFlow.splitSize(line.identity.ficName ?? "")
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                if line.identity.ficName != nil {
                    Text(parts.name).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Non identificato").font(Theme.display(20)).foregroundStyle(Theme.warning)
                    Text("Titolo della fonte, non il nome ufficiale: \(line.identity.sourceTitle)")
                        .font(.footnote).foregroundStyle(Theme.secondary)
                }
                HStack(spacing: 10) {
                    if let size = parts.size { SizeBadge(size: size, strong: highlighted || line.state != "done") }
                    if let codice = line.identity.codice {
                        Text(codice).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Theme.secondary)
                    }
                }
            }
            ForEach(reasons, id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Theme.warning)
            }
            if highlighted {
                Label("In scansione", systemImage: "barcode.viewfinder")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            HStack(spacing: 12) {
                ProgressBar(done: line.verified, total: line.required, height: 6)
                HStack(spacing: 6) {
                    if line.state == "done" {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    }
                    Text(PackingFlow.countLabel(verified: line.verified, required: line.required))
                        .font(Theme.display(20))
                        .foregroundStyle(line.state == "done" ? Theme.success : Theme.ink)
                }
                .fixedSize()
            }
            if line.uncertain > 0 {
                Label("\(line.uncertain) da riscansionare", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(Theme.warning)
            }
            if canRemove && !line.units.isEmpty {
                Button("Togline uno", action: onRemove)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(16)
        .card(border: borderColor, width: highlighted ? 2 : 1)
    }

    private var reasons: [String] {
        [line.kind == "uncertain" ? line.kindReason : nil, line.identity.reason, line.verification?.reason].compactMap { $0 }
    }

    private var borderColor: Color {
        if highlighted { return Theme.accent }
        switch line.state {
        case "done": return Theme.success
        case "blocked", "recheck": return Theme.warning
        default: return Theme.border
        }
    }
}

// MARK: - Bottom sheet for a read

private struct ScanSheet: View {
    let model: PackModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule().fill(Theme.track).frame(width: 40, height: 5).frame(maxWidth: .infinity)
            switch model.card {
            case .offer(let scan): offer(scan)
            case .rejected(let scan): rejected(scan)
            default: EmptyView()
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(Theme.card, in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
        .background(Theme.card.ignoresSafeArea(edges: .bottom))
    }

    @ViewBuilder private func offer(_ scan: Scan) -> some View {
        let parts = PackingFlow.splitSize(scan.productName ?? "")
        let line = model.pack.lines.first { $0.lineId == scan.lineId }
        Label("\(PackingFlow.rightProduct)", systemImage: "barcode.viewfinder")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accent)
        VStack(alignment: .leading, spacing: 8) {
            Text(parts.name.isEmpty ? (scan.codice ?? scan.barcode) : parts.name)
                .font(Theme.display(32)).foregroundStyle(Theme.ink)
            HStack(spacing: 10) {
                if let size = parts.size {
                    Text(size).font(.title2.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10))
                }
                if let code = scan.codice {
                    Text(code).font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(Theme.secondary)
                }
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(scan.recheck ? "Controlla di nuovo" : "Sarebbe il").font(.footnote).foregroundStyle(Theme.secondary)
                Spacer()
                if let line { Text("\(line.verified) contati").font(.footnote).foregroundStyle(Theme.secondary) }
            }
            Text("\(scan.unitNumber ?? 1) di \(scan.required ?? 1)").font(Theme.display(28)).foregroundStyle(Theme.ink)
            if let line { ProgressBar(done: line.verified, total: line.required, height: 6) }
        }
        .padding(16)
        .background(Theme.ground, in: RoundedRectangle(cornerRadius: 18))
        VStack(spacing: 8) {
            Button {
                Task { await model.confirm(scan) }
            } label: {
                Label(PackingFlow.countAction, systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle(height: 62))
            .disabled(model.busy)
            Button("Non ora") { model.card = .idle }
                .buttonStyle(SecondaryButtonStyle(filled: false))
            Text("Il codice indica il tipo di prodotto, non questo pezzo. Il tuo tocco conferma che ce n'è uno in più nella scatola.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func rejected(_ scan: Scan) -> some View {
        HStack(spacing: 12) {
            Circle().fill(Theme.dangerSoft).frame(width: 44, height: 44)
                .overlay(Image(systemName: "xmark").font(.headline.weight(.bold)).foregroundStyle(Theme.danger))
            VStack(alignment: .leading, spacing: 2) {
                Text(title(scan)).font(Theme.display(24)).foregroundStyle(Theme.danger)
                Text("Non contato nell'ordine").font(.subheadline).foregroundStyle(Theme.secondary)
            }
        }
        if let code = scan.codice {
            let scanned = PackingFlow.splitSize(scan.productName ?? "")
            productBox("Hai scansionato", code, scanned.name, scanned.size, Theme.danger)
        } else {
            Text(scan.message).font(.subheadline).foregroundStyle(Theme.body)
        }
        Button("OK") { model.card = .idle }
            .buttonStyle(PrimaryButtonStyle(color: Theme.ink))
    }

    private func productBox(_ label: String, _ code: String, _ name: String, _ size: String?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased()).font(.caption.weight(.semibold)).tracking(0.5).foregroundStyle(color)
            Text(name.isEmpty ? code : name).font(Theme.display(24)).foregroundStyle(Theme.ink).lineLimit(2)
            HStack(spacing: 10) {
                if let size { SizeBadge(size: size, color: color) }
                Text(code).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card(border: color, width: 2, radius: 18)
    }

    private func title(_ scan: Scan) -> String {
        switch scan.outcome {
        case "wrong_product": "Prodotto sbagliato"
        case "excess": "Già completo"
        case "unknown_code": "Codice sconosciuto"
        case "ambiguous_code": "Codice ambiguo"
        default: "Non ancora verificabile"
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
        case "set_aside": "L'ho tolto dalla scatola"
        case "never_in_box": "Non è mai entrato"
        case "repeat_read": "Stesso pezzo letto due volte"
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
    private var total: Int { pack.lines.reduce(0) { $0 + $1.required } }

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
                    Circle().stroke(Theme.success, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    VStack(spacing: 0) {
                        Text("\(total)/\(total)").font(Theme.display(38))
                        Text(PackingFlow.unitWord(total)).font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                .frame(width: 132, height: 132)
                .accessibilityElement(children: .combine)
                Text("È tutto nella scatola").font(Theme.display(28)).foregroundStyle(Theme.ink)

                VStack(spacing: 0) {
                    ForEach(Array(pack.lines.enumerated()), id: \.element.lineId) { index, line in
                        HStack(spacing: 12) {
                                Circle().fill(Theme.success).frame(width: 26, height: 26)
                                    .overlay(Image(systemName: "checkmark").font(.caption.weight(.heavy)).foregroundStyle(.white))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.identity.codice ?? "").font(Theme.code(16)).foregroundStyle(Theme.ink)
                                    Text(line.identity.ficName ?? "").font(.footnote).foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                Text(PackingFlow.countLabel(verified: line.verified, required: line.required))
                                    .font(Theme.display(17)).foregroundStyle(Theme.ink)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)
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
    private var units: Int { pack.lines.reduce(0) { $0 + $1.verified } }

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
                Text("Imballato").font(Theme.display(34)).foregroundStyle(Theme.ink)
                Text(pack.recipient ?? pack.reference).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                Text("\(pack.reference) · \(units) \(PackingFlow.unitWord(units))").font(.subheadline).foregroundStyle(Theme.secondary)
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
                Text("Imballato solo in Packy. Spediscilo come al solito.").font(.caption).foregroundStyle(Theme.secondary)
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
