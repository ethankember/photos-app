import AuthenticationServices
import Core
import CloudCore
import SwiftUI

struct SignInView: View {
    let model: AppModel
    /// Prefilled when adding a second account or re-signing in.
    var initialEmail = ""
    var onSignedIn: (() -> Void)?

    @State private var email = ""
    @State private var password = ""
    @State private var working: Method?
    @State private var errorMessage: String?
    @FocusState private var focus: Field?
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    private enum Field { case email, password }
    private enum Method { case password, singleSignOn }

    private var isWorking: Bool { working != nil }
    /// Until the server has answered, both ways in are offered.
    private var offersPassword: Bool { model.signInOptions?.password ?? true }
    private var offersSingleSignOn: Bool { model.signInOptions?.singleSignOn ?? true }

    var body: some View {
        Form {
            if offersPassword {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(signIn)
                } header: {
                    Text("Cloud account")
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(errorMessage)")
                }
            }

            if offersPassword {
                Section {
                    Button(action: signIn) {
                        HStack {
                            Text("Sign In")
                            Spacer()
                            if working == .password { ProgressView() }
                        }
                    }
                    .disabled(isWorking || email.isEmpty || password.isEmpty)
                }
            }

            if offersSingleSignOn {
                Section {
                    Button(action: signInWithSingleSignOn) {
                        HStack {
                            Text(model.signInOptions?.singleSignOnTitle ?? "Sign In with Single Sign-On")
                            Spacer()
                            if working == .singleSignOn { ProgressView() }
                        }
                    }
                    .disabled(isWorking)
                } footer: {
                    Text("Signs in through your server’s identity provider (OAuth / OpenID Connect).")
                }
            }

            ServerAddressSection(model: model)
        }
        .navigationTitle("Photos")
        .onAppear {
            if email.isEmpty { email = initialEmail }
        }
        // Again whenever another address starts answering (e.g. after editing the server below).
        .task(id: model.connection.activeServer?.url) {
            await model.refreshSignInOptions()
        }
    }

    private func signIn() {
        guard !isWorking, !email.isEmpty, !password.isEmpty else { return }
        working = .password
        errorMessage = nil
        Task {
            defer { working = nil }
            do {
                try await model.signIn(email: email, password: password)
                password = ""
                onSignedIn?()
            } catch {
                errorMessage = (error as? CloudError)?.message ?? error.localizedDescription
            }
        }
    }

    private func signInWithSingleSignOn() {
        guard !isWorking else { return }
        working = .singleSignOn
        errorMessage = nil
        Task {
            defer { working = nil }
            do {
                try await model.signInWithSingleSignOn { url, callbackScheme in
                    try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: callbackScheme)
                }
                onSignedIn?()
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // The sheet was closed: nothing to report.
            } catch {
                errorMessage = (error as? CloudError)?.message ?? error.localizedDescription
            }
        }
    }
}

/// Editable local/remote addresses with a per-address connection test.
struct ServerAddressSection: View {
    let model: AppModel

    @State private var local = ""
    @State private var remote = ""
    @State private var report: [String]?
    @State private var isTesting = false

    var body: some View {
        Section {
            LabeledContent("Home") {
                TextField("192.168.1.10:2283", text: $local)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Away") {
                TextField("100.64.0.10:2283", text: $remote)
                    .multilineTextAlignment(.trailing)
            }
            Button {
                test()
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if isTesting { ProgressView() }
                }
            }
            .disabled(isTesting)
            if let report {
                ForEach(report, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(line.contains("OK") ? Color.secondary : Color.red)
                }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("The home address is used when it answers within 1.5 seconds; otherwise the away address (Tailscale).")
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
        .onAppear {
            local = model.serverSettings.addresses.local?.absoluteString ?? ""
            remote = model.serverSettings.addresses.remote?.absoluteString ?? ""
        }
        .onChange(of: local) { save() }
        .onChange(of: remote) { save() }
    }

    private func save() {
        let addresses = ServerAddresses(local: ServerAddresses.normalize(local), remote: ServerAddresses.normalize(remote))
        guard addresses != model.serverSettings.addresses else { return }
        model.serverSettings.addresses = addresses
        model.reconnect()
    }

    private func test() {
        isTesting = true
        Task {
            report = await model.connectivityReport()
            isTesting = false
        }
    }
}
