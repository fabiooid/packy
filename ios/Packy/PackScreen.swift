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
            if pack.status == "active" && pack.isOwner {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Stop") { confirmingEmpty = true }
                        .accessibilityLabel("Stop and put items back")
                }
            }
        }
        .confirmationDialog("Mark \(pack.reference) as done?", isPresented: $confirmingComplete, titleVisibility: .visible) {
            Button("Mark as done") { Task { await model.completeAfterRefresh() } }
        } message: {
            Text("You are saying the box matches this order. This does not ship it.")
        }
        .confirmationDialog("Stop and put items back?", isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("Stop and put items back", role: .destructive) {
                Task { if await model.emptyBox() { dismiss() } }
            }
        } message: {
            Text("The count will be cleared. Put every item back. This order will look not started.")
        }
        .confirmationDialog("Pack \(pack.reference) again from the start?", isPresented: $confirmingAgain, titleVisibility: .visible) {
            Button("Pack this again", role: .destructive) {
                Task { if await model.emptyBox() { dismiss() } }
            }
        } message: {
            Text("The done record will be cleared. Put the items back, then scan them again.")
        }
        .confirmationDialog("Why is this unit coming out?", isPresented: removingShown, titleVisibility: .visible, presenting: removing) { line in
            ForEach([("damaged", "Damaged"), ("miscounted", "Miscounted"), ("other", "Other")], id: \.0) { reason in
                Button(reason.1) {
                    if let unit = line.units.last {
                        Task { await model.perform("units/\(unit.id)/remove", extra: ["reason": reason.0]) }
                    }
                }
            }
        } message: { _ in
            Text("Its credit is removed. Take it out of the box.")
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
                   text: "Done. This is a packing record only. It does not ship the order.")
            if pack.changedAfterCompletion {
                Notice(icon: "exclamationmark.triangle.fill", color: .red, text: "This order changed after it was marked done.")
            }
            if pack.isOwner {
                Button("Pack this again") { confirmingAgain = true }.buttonStyle(.bordered)
            }
        }
        if !pack.isOwner && pack.status == "active" {
            Notice(icon: "eye", color: .secondary, text: "This order is open on another phone. You can look.")
        }
        if !pack.eligible {
            Notice(icon: "xmark.octagon.fill", color: .red, text: "\(pack.ineligibleReason ?? "This order cannot be packed.") Do not ship this box.")
        }
        if let message = pack.freshness.message {
            Notice(icon: "clock.badge.exclamationmark", color: .orange, text: message)
            Button("Refresh now") { Task { await model.refresh() } }.buttonStyle(.bordered)
        }
    }

    /// The discrepancy from the latest scan is resolved in the scan card, right under the camera.
    private var listedDiscrepancies: [Discrepancy] {
        guard case .rejected(let scan) = model.card else { return pack.discrepancies }
        return pack.discrepancies.filter { $0.id != scan.discrepancyId }
    }

    @ViewBuilder private var discrepancies: some View {
        if !listedDiscrepancies.isEmpty {
            SectionTitle("Account for these items")
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
            SectionTitle("The order changed")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(pack.changes) { Text($0.message).font(.subheadline) }
                if pack.isOwner && pack.status == "active" {
                    Button {
                        Task { await model.perform("reconcile") }
                    } label: {
                        Text("Use the updated order").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
            .cardStyle(border: .orange)
        }
    }

    private var orderedLines: [Line] {
        pack.lines.sorted { ($0.state == "done" ? 1 : 0) < ($1.state == "done" ? 1 : 0) }
    }

    @ViewBuilder private var lines: some View {
        SectionTitle("Items")
        ForEach(orderedLines) { line in
            LineRow(line: line, canRemove: pack.isOwner && pack.status == "active") { removing = line }
        }
    }

    @ViewBuilder private var nonPhysical: some View {
        if !pack.nonPhysical.isEmpty {
            SectionTitle("Not physical, no scan needed")
            ForEach(pack.nonPhysical) { row in
                Text("\(row.title) (\(row.reason))").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var blockerList: some View {
        if pack.status == "active" && !pack.blockers.isEmpty {
            SectionTitle("Before this can be done")
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
                        Text("Mark as done")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                } else if unitsStillToDo > 0 {
                    Text("\(unitsStillToDo) still to do")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not ready yet")
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
        case "set_aside": "It is out of the box"
        case "never_in_box": "It never went in the box"
        case "repeat_read": "Same item read twice, no extra"
        default: resolution
        }
    }
}

private struct ScanCardView: View {
    let model: PackModel

    var body: some View {
        switch model.card {
        case .idle:
            Text("Point at one bottle.")
                .font(.subheadline).foregroundStyle(.secondary)
        case .checking(let code):
            HStack {
                ProgressView()
                Text("Read \(code). Checking...").font(.subheadline.monospacedDigit())
            }
        case .offer(let scan):
            VStack(alignment: .leading, spacing: 8) {
                Label("Right bottle. Not counted yet.", systemImage: "barcode.viewfinder").font(.subheadline.bold()).foregroundStyle(.blue)
                Text(scan.codice ?? "").font(.title.bold().monospaced())
                Text(scan.productName ?? "").font(.headline)
                Text("\(scan.unitNumber ?? 1) of \(scan.required ?? 1)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Button {
                    Task { await model.confirm(scan) }
                } label: {
                    Text("Count this bottle").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
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
                Label("No answer from the server. This unit may not be recorded.", systemImage: "wifi.exclamationmark").font(.subheadline.bold()).foregroundStyle(.red)
                Button {
                    Task { await model.confirm(scan, actionId: actionId) }
                } label: {
                    Text("Try again (cannot count twice)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .cardStyle(border: .red)
        }
    }

    private func title(_ scan: Scan) -> String {
        switch scan.outcome {
        case "wrong_product": "Wrong bottle. Not counted."
        case "excess": "Already done. Not counted."
        case "unknown_code": "Unknown code. Not counted."
        case "ambiguous_code": "Unclear code. Not counted."
        default: "Cannot be checked. Not counted."
        }
    }
}

private struct LineRow: View {
    let line: Line
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if let codice = line.identity.codice {
                    Text(codice).font(.title3.bold().monospaced())
                } else {
                    Text("Unresolved").font(.title3.bold()).foregroundStyle(.orange)
                }
                Spacer()
                Text(line.state == "done" ? "Done" : "To do")
                    .font(.subheadline.bold())
                    .foregroundStyle(line.state == "done" ? .green : .secondary)
            }
            Text("\(line.verified) of \(line.required)").font(.title3.bold().monospacedDigit()).foregroundStyle(countColor)
            if let name = line.identity.ficName {
                Text(name).font(.subheadline)
            } else {
                Text("Source title, not an FIC name: \(line.identity.sourceTitle)").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(reasons, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange) }
            if line.uncertain > 0 {
                Label("\(line.uncertain) to scan again", systemImage: "arrow.triangle.2.circlepath").font(.footnote).foregroundStyle(.orange)
            }
            if canRemove && !line.units.isEmpty {
                Button("Take one out", action: onRemove).font(.footnote)
            }
        }
        .cardStyle(border: borderColor)
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
