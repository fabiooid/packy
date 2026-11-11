import SwiftUI

struct PackScreen: View {
    @Bindable var model: PackModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingComplete = false
    @State private var confirmingEmpty = false
    @State private var confirmingAgain = false
    @State private var removing: Line?

    private var pack: Pack { model.pack }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                banners
                if pack.canScan {
                    ScannerPanel { code, symbology in model.handleRead(code, symbology: symbology) }
                    ScanCardView(model: model)
                } else if case .notRecorded = model.card {
                    ScanCardView(model: model)
                } else if case .failure = model.card {
                    ScanCardView(model: model)
                }
                discrepancies
                changes
                lines
                nonPhysical
                blockerList
                Text(pack.limitsNote).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .navigationTitle(pack.reference)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(pack.status == "active" && pack.isOwner)
        .background(BackSwipeLock(locked: pack.status == "active" && pack.isOwner))
        .refreshable { await model.refresh() }
        .safeAreaInset(edge: .bottom) { footer }
        .toolbar {
            if pack.canLeave {
                ToolbarItem(placement: .cancellationAction) {
                    Button(PackingFlow.leaveAction) { confirmingEmpty = true }
                }
            }
        }
        .confirmationDialog("Segnare \(pack.reference) come completato?", isPresented: $confirmingComplete, titleVisibility: .visible) {
            Button("Segna come completato") { Task { await model.completeAfterRefresh() } }
        } message: {
            Text(PackingFlow.markDoneConfirm)
        }
        .confirmationDialog(PackingFlow.leaveAction, isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button(PackingFlow.leaveAction) {
                Task { if await model.emptyBox() { dismiss() } }
            }
        }
        .confirmationDialog("Imballare di nuovo \(pack.reference) da capo?", isPresented: $confirmingAgain, titleVisibility: .visible) {
            Button("Imballa di nuovo", role: .destructive) {
                Task { if await model.emptyBox() { dismiss() } }
            }
        } message: {
            Text("Il record di completamento verrà cancellato. Rimetti i pezzi, poi scansiona di nuovo.")
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

    private var removingShown: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    @ViewBuilder private var banners: some View {
        if pack.fixture { FixtureBanner() }
        if let recipient = pack.recipient {
            Text(recipient).font(.subheadline).foregroundStyle(.secondary)
        }
        if pack.status == "completed" {
            Notice(icon: "checkmark.seal.fill", color: .green,
                   text: "Completato. Questo è solo un record di imballaggio. Non spedisce l'ordine.")
            if pack.changedAfterCompletion {
                Notice(icon: "exclamationmark.triangle.fill", color: .red, text: "L'ordine è cambiato dopo essere stato segnato come completato.")
            }
            if pack.isOwner {
                Button("Imballa di nuovo") { confirmingAgain = true }.buttonStyle(.bordered)
            }
        }
        if !pack.isOwner && pack.status == "active" {
            Notice(icon: "eye", color: .secondary, text: "Aperto su un altro telefono. Puoi solo guardare.")
        }
        if !pack.eligible {
            Notice(icon: "xmark.octagon.fill", color: .red, text: "\(pack.ineligibleReason ?? "Questo ordine non si può imballare.") Non spedire questa scatola.")
        }
        if let message = pack.freshness.message {
            Notice(icon: "clock.badge.exclamationmark", color: .orange, text: message)
            Button("Aggiorna ora") { Task { await model.refresh() } }.buttonStyle(.bordered)
        }
    }

    /// The discrepancy from the latest scan is resolved in the scan card, right under the camera.
    private var listedDiscrepancies: [Discrepancy] {
        guard case .rejected(let scan) = model.card else { return pack.discrepancies }
        return pack.discrepancies.filter { $0.id != scan.discrepancyId }
    }

    @ViewBuilder private var discrepancies: some View {
        if !listedDiscrepancies.isEmpty {
            SectionTitle("Sistemare questi pezzi")
            ForEach(listedDiscrepancies) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.headline)
                    Text(item.detail).font(.subheadline)
                    if pack.isOwner { ResolutionButtons(item: item, model: model) }
                }
                .cardStyle(border: .red)
            }
        }
    }

    @ViewBuilder private var changes: some View {
        if !pack.changes.isEmpty {
            SectionTitle("L'ordine è cambiato")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(pack.changes) { Text($0.message).font(.subheadline) }
                if pack.isOwner && pack.status == "active" {
                    Button {
                        Task { await model.perform("reconcile") }
                    } label: {
                        Text("Usa l'ordine aggiornato").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
            .cardStyle(border: .orange)
        }
    }

    private var highlightedLineId: String? {
        if case .offer(let scan) = model.card { return scan.lineId }
        return nil
    }

    @ViewBuilder private var lines: some View {
        SectionTitle("Items")
        Text(PackingFlow.productListHint).font(.subheadline).foregroundStyle(.secondary)
        ForEach(pack.lines) { line in
            LineRow(
                line: line,
                highlighted: line.id == highlightedLineId,
                canRemove: pack.isOwner && pack.status == "active"
            ) { removing = line }
        }
    }

    @ViewBuilder private var nonPhysical: some View {
        if !pack.nonPhysical.isEmpty {
            SectionTitle("Non fisico, nessuna scansione")
            ForEach(pack.nonPhysical) { row in
                Text("\(row.title) (\(row.reason))").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var blockerList: some View {
        if pack.status == "active" && !pack.blockers.isEmpty {
            SectionTitle("Prima di completare")
            ForEach(pack.blockers) { Text($0.message).font(.subheadline) }
        }
    }

    /// Bottles that still need a count, including ones that must be checked again.
    private var unitsStillToDo: Int {
        pack.lines.reduce(0) { $0 + $1.remaining + $1.uncertain }
    }

    @ViewBuilder private var footer: some View {
        if pack.status == "active" && pack.isOwner {
            Group {
                if pack.canComplete {
                    Button { confirmingComplete = true } label: {
                        Text("Segna come completato")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                } else if unitsStillToDo > 0 {
                    Text("\(unitsStillToDo) still to do")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Non ancora pronto")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

private struct ResolutionButtons: View {
    let item: Discrepancy
    let model: PackModel

    var body: some View {
        ForEach(item.resolutions, id: \.self) { resolution in
            Button {
                Task { await model.perform("discrepancies/\(item.id)/resolve", extra: ["resolution": resolution]) }
            } label: {
                Text(Self.label(for: resolution)).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    private static func label(for resolution: String) -> String {
        switch resolution {
        case "set_aside": "L'ho tolto dalla scatola"
        case "never_in_box": "Non è mai entrato"
        case "repeat_read": "Stesso pezzo letto due volte"
        default: resolution
        }
    }
}

private struct ScanCardView: View {
    let model: PackModel

    var body: some View {
        switch model.card {
        case .idle:
            Text(PackingFlow.cameraWaiting)
                .font(.subheadline).foregroundStyle(.secondary)
        case .checking(let code):
            HStack {
                ProgressView()
                Text("Read \(code). Checking...").font(.subheadline.monospacedDigit())
            }
        case .offer(let scan):
            VStack(alignment: .leading, spacing: 8) {
                Label(PackingFlow.rightProduct, systemImage: "barcode.viewfinder").font(.subheadline.bold()).foregroundStyle(.blue)
                Text(scan.codice ?? "").font(.title.bold().monospaced())
                Text(scan.productName ?? "").font(.headline)
                Text("\(scan.unitNumber ?? 1) of \(scan.required ?? 1)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Button {
                    Task { await model.confirm(scan) }
                } label: {
                    Text(PackingFlow.countAction).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)
            }
            .cardStyle(border: .blue)
        case .recorded(let message):
            Label(message, systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green).cardStyle(border: .green)
        case .rejected(let scan):
            VStack(alignment: .leading, spacing: 6) {
                Label(title(scan), systemImage: "xmark.octagon.fill").font(.headline).foregroundStyle(.red)
                if let codice = scan.codice, !codice.isEmpty {
                    Text(codice).font(.title.bold().monospaced())
                }
                if let name = scan.productName, !name.isEmpty {
                    Text(name).font(.headline)
                }
                Text(scan.message).font(.subheadline)
                Text("Code \(scan.barcode)").font(.caption.monospaced()).foregroundStyle(.secondary)
                if let item = model.pack.discrepancies.first(where: { $0.id == scan.discrepancyId }) {
                    Text(item.detail).font(.subheadline.bold())
                    ResolutionButtons(item: item, model: model)
                }
            }
            .cardStyle(border: .red)
        case .notRecorded(let message), .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.subheadline.bold()).foregroundStyle(.red).cardStyle(border: .red)
        case .unknownResult(let scan, let actionId):
            VStack(alignment: .leading, spacing: 8) {
                Label("Nessuna risposta dal server. Questo pezzo potrebbe non essere contato.", systemImage: "wifi.exclamationmark").font(.subheadline.bold()).foregroundStyle(.red)
                Button {
                    Task { await model.confirm(scan, actionId: actionId) }
                } label: {
                    Text("Riprova (non può contare due volte)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .cardStyle(border: .red)
        }
    }

    private func title(_ scan: Scan) -> String {
        switch scan.outcome {
        case "wrong_product": PackingFlow.wrongProductTitle
        case "excess": "Già completo. Non contato."
        case "unknown_code": "Codice sconosciuto. Non contato."
        case "ambiguous_code": "Codice ambiguo. Non contato."
        default: "Non ancora verificabile. Non contato."
        }
    }
}

private struct LineRow: View {
    let line: Line
    var highlighted = false
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if let name = line.identity.ficName {
                        Text(name).font(.subheadline)
                    } else {
                        Text("Titolo della fonte, non un nome ufficiale: \(line.identity.sourceTitle)").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let codice = line.identity.codice {
                        Text(codice).font(.title3.bold().monospaced())
                    } else {
                        Text("Unresolved").font(.title3.bold()).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Text(PackingFlow.countLabel(verified: line.verified, required: line.required))
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(countColor)
            }
            ForEach(reasons, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange) }
            if line.uncertain > 0 {
                Label("\(line.uncertain) to scan again", systemImage: "arrow.triangle.2.circlepath").font(.footnote).foregroundStyle(.orange)
            }
            if canRemove && !line.units.isEmpty {
                Button("Take one out", action: onRemove).font(.footnote)
            }
        }
        .cardStyle(border: highlighted ? .blue : borderColor)
    }

    private var reasons: [String] {
        [line.kind == "uncertain" ? line.kindReason : nil, line.identity.reason, line.verification?.reason].compactMap { $0 }
    }

    private var countColor: Color { line.state == "done" ? .green : .primary }

    private var borderColor: Color {
        switch line.state {
        case "done": .green
        case "blocked", "recheck": .orange
        default: Color(.separator)
        }
    }
}

private struct Notice: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        Label(text, systemImage: icon).font(.subheadline).foregroundStyle(color)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.subheadline.bold()).foregroundStyle(.secondary).padding(.top, 4)
    }
}

/// Keeps an open order from being left by the edge swipe. Leaving is the Stop button, which asks first.
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

private extension View {
    func cardStyle(border: Color) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 1.5))
    }
}
