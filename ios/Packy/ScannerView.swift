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
        .frame(height: 210)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var content: some View {
        switch authorization {
        case .authorized:
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                CameraScanner(onRead: onRead).overlay { AimGuide() }
            } else {
                unavailable("This iPhone cannot scan right now, so nothing can be verified.")
            }
        case .notDetermined:
            Color.black.task {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                authorization = AVCaptureDevice.authorizationStatus(for: .video)
            }
        default:
            VStack(spacing: 10) {
                unavailable("Camera access is off, so nothing can be verified.")
                Button("Open Settings") {
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

private struct AimGuide: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(.white.opacity(0.8), lineWidth: 2)
            .padding(.horizontal, 36)
            .padding(.vertical, 44)
            .allowsHitTesting(false)
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
        VStack(alignment: .leading, spacing: 10) {
            Text(PackingFlow.cameraSimulator)
                .font(.caption)
                .foregroundStyle(.white)
            ForEach(codes, id: \.1) { code in
                Button(code.0) { onRead(code.1, "simulated") }
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}
#endif
