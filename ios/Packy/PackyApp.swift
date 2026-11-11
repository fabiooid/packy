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
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text("Packy").font(.largeTitle.bold())
            Text(PackingFlow.signInPurpose).foregroundStyle(.secondary)
            Text(PackingFlow.operatorField).font(.subheadline)
            TextField(PackingFlow.operatorHint, text: $username)
                .textContentType(.name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textContentType(.oneTimeCode)
                .textFieldStyle(.roundedBorder)
            if let error = model.loginError {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Button {
                working = true
                Task {
                    await model.login(username: username, password: password)
                    password = ""
                    working = false
                }
            } label: {
                Text(working ? "Accesso in corso..." : "Accedi").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(working || username.isEmpty || password.isEmpty)
            Spacer()
            Spacer()
        }
        .padding(24)
    }
}
