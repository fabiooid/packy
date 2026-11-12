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
            // Login sits on deep blue, so it needs light status-bar text. Everything else is light.
            .preferredColorScheme(model.signedIn ? .light : .dark)
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
                    Image("LoginMark")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Packy").font(Theme.display(40)).foregroundStyle(Theme.cream)
                        Text(PackingFlow.signInPurpose).font(.title3).foregroundStyle(Theme.cream.opacity(0.92))
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    field(PackingFlow.operatorField) {
                        TextField("", text: $username, prompt: Text(PackingFlow.operatorHint).foregroundStyle(Theme.secondary))
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
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button {
                        working = true
                        Task {
                            await model.login(username: username, password: password)
                            password = ""
                            working = false
                        }
                    } label: {
                        if working { ProgressView().tint(Theme.brandDeep) } else { Text("Accedi") }
                    }
                    .buttonStyle(PrimaryButtonStyle(color: Theme.cream, foreground: Theme.brandDeep, onDark: true))
                    .disabled(working || username.isEmpty || password.isEmpty)
                    .padding(.top, 6)
                }

                Text("Password dimenticata? Chiedi al responsabile.")
                    .font(.footnote)
                    .foregroundStyle(Theme.cream.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 56)
        }
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(colors: [Theme.brandDeep, Theme.brandNight], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func field<Content: View>(_ label: String, @ViewBuilder input: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.cream)
            input()
                .font(.title3)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 16)
                .frame(height: 54)
                .card(border: Theme.border, width: 1.5, radius: 14)
        }
    }
}
