import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: MailStore
    @State private var clientID: String = OAuthConfig.clientID
    @State private var clientSecret: String = OAuthConfig.clientSecret

    var body: some View {
        TabView {
            Form {
                Section {
                    TextField("Client ID", text: $clientID)
                        .onChange(of: clientID) { OAuthConfig.clientID = clientID }
                    SecureField("Client Secret", text: $clientSecret)
                        .onChange(of: clientSecret) { OAuthConfig.clientSecret = clientSecret }
                } header: {
                    Text("Google OAuth (Desktop app client)")
                } footer: {
                    Text("Create a free OAuth client in Google Cloud Console → APIs & Services → Credentials → Create Credentials → OAuth client ID → Desktop app. The secret is stored in your Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Google API", systemImage: "key") }

            Form {
                ForEach(store.accounts) { account in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.id)
                            if let last = account.lastSyncAt {
                                Text("Last sync \(last, format: .relative(presentation: .named))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            store.removeAccount(account.id)
                        }
                    }
                }
                Button("Add Google Account…") { store.addAccount() }
            }
            .formStyle(.grouped)
            .tabItem { Label("Accounts", systemImage: "person.2") }

            SnippetsSettings()
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }

            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "textformat.size") }

            AISettings()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 520, height: 380)
    }
}

struct AppearanceSettings: View {
    @AppStorage("fontScale") private var fontScale = 1.0

    var body: some View {
        Form {
            Section {
                Picker("Text size", selection: $fontScale) {
                    Text("Small").tag(0.9)
                    Text("Default").tag(1.0)
                    Text("Large").tag(1.15)
                    Text("Extra Large").tag(1.3)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Also adjustable anywhere with Cmd + and Cmd −.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AISettings: View {
    @State private var url: String = Ollama.baseURL
    @State private var model: String = Ollama.model

    var body: some View {
        Form {
            Section {
                TextField("Ollama URL", text: $url)
                    .onChange(of: url) { Ollama.baseURL = url }
                TextField("Model", text: $model)
                    .onChange(of: model) { Ollama.model = model }
            } header: {
                Text("Local AI drafting (Ollama)")
            } footer: {
                Text("AI drafting runs entirely on this Mac via Ollama. Install from ollama.com, then run: ollama pull \(model). The Draft with AI button appears when replying.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SnippetsSettings: View {
    @EnvironmentObject var store: MailStore
    @State private var name = ""
    @State private var body_ = ""
    @State private var refresh = 0

    var body: some View {
        Form {
            Section("New snippet") {
                TextField("Name", text: $name)
                TextField("Body", text: $body_, axis: .vertical).lineLimit(3...6)
                Button("Add") {
                    store.saveSnippet(name: name, body: body_)
                    name = ""; body_ = ""; refresh += 1
                }
                .disabled(name.isEmpty || body_.isEmpty)
            }
            Section("Saved") {
                ForEach(store.snippets()) { s in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.name).font(.system(size: 12, weight: .medium))
                            Text(s.body).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Delete", role: .destructive) {
                            store.deleteSnippet(s); refresh += 1
                        }
                    }
                }
            }
            .id(refresh)
        }
        .formStyle(.grouped)
    }
}
