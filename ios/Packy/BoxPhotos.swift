import SwiftUI
import UIKit

enum BoxPhoto {
    static func jpeg(_ image: UIImage, maxSide: CGFloat = 1600, quality: CGFloat = 0.7) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > 0 ? min(1, maxSide / longest) : 1
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: quality)
    }

    /// Synthetic stand-in for Simulator tests. No customer data.
    static func sampleJpeg() -> Data {
        let size = CGSize(width: 320, height: 240)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.92, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.55, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 90, y: 60, width: 140, height: 100), cornerRadius: 10).fill()
            UIColor(white: 0.35, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: 90, y: 60, width: 140, height: 18)).fill()
        }
        return jpeg(image) ?? Data()
    }
}

struct BoxCountStepper: View {
    let count: Int
    var enabled = true
    let onChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PackingFlow.boxesQuestion).font(.headline).foregroundStyle(Theme.ink)
            HStack(spacing: 16) {
                stepButton("minus", enabled: enabled && count > PackingFlow.defaultBoxCount) {
                    onChange(count - 1)
                }
                Text("\(count) \(PackingFlow.boxWord(count))")
                    .font(Theme.display(22))
                    .foregroundStyle(Theme.ink)
                    .frame(minWidth: 120)
                    .accessibilityLabel("\(count) \(PackingFlow.boxWord(count))")
                stepButton("plus", enabled: enabled && count < PackingFlow.maxBoxCount) {
                    onChange(count + 1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .card()
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.bold))
                .foregroundStyle(enabled ? Theme.ink : Theme.track)
                .frame(width: 44, height: 44)
                .background(Theme.divider, in: Circle())
        }
        .disabled(!enabled)
        .accessibilityLabel(symbol == "plus" ? "Aggiungi una scatola" : "Togli una scatola")
    }
}

struct BoxPhotoSlot: View {
    let packId: String
    let index: Int
    let total: Int
    let taken: Bool
    var editable = true
    let onCapture: (Data) -> Void
    @State private var capturing = false
    @State private var preview: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PackingFlow.boxLabel(index, total: total)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Theme.divider)
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFill()
                } else if taken {
                    AuthenticatedImage(packId: packId, boxIndex: index)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "camera").font(.system(size: 28, weight: .medium))
                        Text(PackingFlow.photoPrompt)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 16)
                }
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(taken || preview != nil ? Theme.success : Theme.border, lineWidth: 1.5))
            if editable {
                Button {
                    capturing = true
                } label: {
                    Label(taken || preview != nil ? PackingFlow.photoRetake : PackingFlow.photoCapture, systemImage: "camera.fill")
                }
                .buttonStyle(PrimaryButtonStyle(color: taken || preview != nil ? Theme.ink : Theme.accent, height: 48))
            }
        }
        .padding(16)
        .card()
        .fullScreenCover(isPresented: $capturing) {
            BoxCamera { data in
                preview = UIImage(data: data)
                onCapture(data)
            }
        }
    }
}

struct PackedPhotoStrip: View {
    let packId: String
    let boxCount: Int
    let photos: [PackPhoto]
    var heading = true

    var body: some View {
        if !photos.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if heading { SectionLabel(PackingFlow.photosHeading) }
                ForEach(photos) { photo in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(PackingFlow.boxLabel(photo.boxIndex, total: boxCount))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.secondary)
                        AuthenticatedImage(packId: packId, boxIndex: photo.boxIndex)
                            .frame(maxWidth: .infinity)
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
                    }
                }
            }
        }
    }
}

struct AuthenticatedImage: View {
    let packId: String
    let boxIndex: Int
    @Environment(AppModel.self) private var app
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(packId)-\(boxIndex)") {
            image = await app.api.loadPhoto(packId: packId, boxIndex: boxIndex)
        }
    }
}

struct BoxCamera: View {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if targetEnvironment(simulator)
        NavigationStack {
            SimulatedBoxCamera {
                onCapture(BoxPhoto.sampleJpeg())
                dismiss()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }.foregroundStyle(Theme.ink)
                }
            }
        }
        #else
        CameraPicker(
            onCapture: { image in
                if let data = BoxPhoto.jpeg(image) { onCapture(data) }
                dismiss()
            },
            onCancel: { dismiss() }
        )
        .ignoresSafeArea()
        #endif
    }
}

#if targetEnvironment(simulator)
private struct SimulatedBoxCamera: View {
    let onCapture: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder").font(.system(size: 40, weight: .medium))
            Text(PackingFlow.cameraSimulatorPhoto)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button(PackingFlow.photoCapture, action: onCapture)
                .buttonStyle(PrimaryButtonStyle(height: 50))
        }
        .foregroundStyle(Theme.ink)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }
}
#endif

#if !targetEnvironment(simulator)
private struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onCancel: () -> Void
        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onCapture(image) } else { onCancel() }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCancel() }
    }
}
#endif
