import SwiftUI

@main
struct PackyApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if model.signedIn {
                    WorkloadView()
                } else {
                    LoginView()
                }
            }
            .environment(model)
            .preferredColorScheme(.light)
            .environment(\.locale, Locale(identifier: "it_IT"))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.signedIn { Task { await model.refresh() } }
        }
    }
}

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var password = ""
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Theme.accent)
                        .frame(width: 64, height: 64)
                        .overlay(Image(systemName: "shippingbox").font(.system(size: 30, weight: .medium)).foregroundStyle(.white))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Packy").font(Theme.display(40)).foregroundStyle(Theme.ink)
                        Text(PackingFlow.signInPurpose).font(.title3).foregroundStyle(Theme.body)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    field(PackingFlow.operatorField) {
                        TextField(PackingFlow.operatorHint, text: $username)
                            .textContentType(.name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    field("Password") {
                        SecureField("", text: $password).textContentType(.oneTimeCode)
                    }
                    if let error = model.loginError {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.danger)
                    }
                    Button {
                        working = true
                        Task {
                            await model.login(username: username, password: password)
                            password = ""
                            working = false
                        }
                    } label: {
                        if working { ProgressView().tint(.white) } else { Text("Accedi") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(working || username.isEmpty || password.isEmpty)
                    .padding(.top, 6)
                }

                Text("Hai dimenticato l'accesso? Chiedi a chi gestisce Packy.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 56)
        }
        .background(Theme.ground.ignoresSafeArea())
    }

    private func field<Content: View>(_ label: String, @ViewBuilder input: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
            input()
                .font(.title3)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 16)
                .frame(height: 54)
                .card(border: Color(hex: 0xD6D3CC), width: 1.5, radius: 14)
        }
    }
}
