import AVFoundation
import SwiftUI
import VisionKit

/// The camera panel. Every state where scanning is impossible says so, and offers no manual entry:
/// typing a code is not physical verification unless a policy approves it.
struct ScannerPanel: View {
    let onRead: (String, String?) -> Void
    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            #if targetEnvironment(simulator)
            SimulatedScanner(onRead: onRead)
            #else
            content
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var content: some View {
        switch authorization {
        case .authorized:
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                CameraScanner(onRead: onRead).overlay { AimGuide() }
            } else {
                unavailable("Questo iPhone ora non può scansionare, quindi non si può verificare nulla.")
            }
        case .notDetermined:
            Color.black.task {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                authorization = AVCaptureDevice.authorizationStatus(for: .video)
            }
        default:
            VStack(spacing: 10) {
                unavailable("L'accesso alla fotocamera è disattivato, quindi non si può verificare nulla.")
                Button("Apri Impostazioni") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func unavailable(_ text: String) -> some View {
        Label(text, systemImage: "camera.badge.exclamationmark")
            .foregroundStyle(.white)
            .padding()
    }
}

/// Corner brackets mark where reads count. Reads outside it are ignored.
struct AimGuide: View {
    var color: Color = .white

    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width - 72, 280)
            let h = min(geo.size.height - 70, 130)
            ZStack {
                ForEach(0..<4, id: \.self) { corner in
                    Bracket()
                        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 26, height: 26)
                        .rotationEffect(.degrees(Double(corner) * 90))
                        .offset(x: (corner == 0 || corner == 3 ? -1 : 1) * (w / 2 - 13),
                                y: (corner < 2 ? -1 : 1) * (h / 2 - 13))
                }
                Capsule().fill(Theme.accent).frame(width: w - 36, height: 2)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }
}

private struct Bracket: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 8))
        path.addQuadCurve(to: CGPoint(x: rect.minX + 8, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

private struct CameraScanner: UIViewControllerRepresentable {
    let onRead: (String, String?) -> Void

    func makeUIViewController(context: Context) -> ScannerHost {
        ScannerHost(onRead: onRead)
    }

    func updateUIViewController(_ controller: ScannerHost, context: Context) {
        controller.onRead = onRead
    }
}

/// Hosts the scanner so it can follow view lifecycle and keep reads inside the aim guide,
/// which limits stray reads from neighbouring stock.
final class ScannerHost: UIViewController, DataScannerViewControllerDelegate {
    var onRead: (String, String?) -> Void
    private var gate = ScanGate()
    private let scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128])],
        qualityLevel: .accurate,
        recognizesMultipleItems: false,
        isHighFrameRateTrackingEnabled: false,
        isPinchToZoomEnabled: true,
        isGuidanceEnabled: false,
        isHighlightingEnabled: true
    )

    init(onRead: @escaping (String, String?) -> Void) {
        self.onRead = onRead
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(scanner)
        scanner.view.frame = view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)
        scanner.delegate = self
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scanner.regionOfInterest = view.bounds.insetBy(dx: 36, dy: 44)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        try? scanner.startScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner.stopScanning()
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for case let .barcode(code) in addedItems {
            // The payload goes to the server untouched, as an exact string.
            guard let value = code.payloadStringValue, gate.appeared(value) else { continue }
            onRead(value, code.observation.symbology.rawValue)
        }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for case let .barcode(code) in removedItems {
            if let value = code.payloadStringValue { gate.left(value) }
        }
    }
}

#if targetEnvironment(simulator)
/// The Simulator has no camera. This panel does not exist in device builds.
/// It stands in for the live viewfinder and still follows the confirm path.
private struct SimulatedScanner: View {
    let onRead: (String, String?) -> Void
    private let codes = [("MS001", "8050038450997"), ("MS002", "8050038450980"), ("MS024", "0806812399109"), ("MS040", "0806812399192"), ("Unknown", "0000000000000")]

    var body: some View {
        VStack(spacing: 10) {
            AimGuide()
            Text("Simulatore: nessuna fotocamera. Scegli una lettura di prova.")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(codes, id: \.1) { code in
                        Button(code.0) { onRead(code.1, "simulated") }
                            .font(.footnote.monospaced().weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(.white.opacity(0.16), in: Capsule())
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 10)
    }
}
#endif
