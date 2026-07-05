import SwiftUI
import UniformTypeIdentifiers

/// First-run guide. The Google Cloud setup is the biggest onboarding friction
/// versus a one-click OAuth product, so this walks it step by step with
/// deep-links to the exact console pages and a drop target for the downloaded
/// `client_secret_*.json` (so it's one file instead of two copy-pastes).
struct OnboardingView: View {
    @EnvironmentObject var store: MailStore
    @State private var clientID = OAuthConfig.clientID
    @State private var clientSecret = OAuthConfig.clientSecret
    @State private var importing = false
    @State private var importNote: String?

    private var configured: Bool {
        clientID.hasSuffix(".apps.googleusercontent.com") && !clientSecret.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PMSpacing.lg) {
                header

                step(1, "Create a Google Cloud project & enable Gmail") {
                    Text("Create a project, then enable the Gmail API for it.")
                        .font(PMFont.secondary()).foregroundStyle(.secondary)
                    HStack(spacing: PMSpacing.sm) {
                        linkButton("New project", "https://console.cloud.google.com/projectcreate")
                        linkButton("Enable Gmail API", "https://console.cloud.google.com/apis/library/gmail.googleapis.com")
                    }
                }

                step(2, "Configure the consent screen") {
                    Text("User type **External**; add your own Google address under **Test users**. Leave it in **Testing** mode — no Google verification needed. During sign-in you'll see a \u{201C}Google hasn't verified this app\u{201D} screen; that's expected — click **Advanced → Continue**.")
                        .font(PMFont.secondary()).foregroundStyle(.secondary)
                    linkButton("Open consent screen", "https://console.cloud.google.com/apis/credentials/consent")
                }

                step(3, "Create a Desktop OAuth client") {
                    Text("Credentials → Create Credentials → OAuth client ID → **Desktop app**. Then either **drop the downloaded JSON** here or paste the two values.")
                        .font(PMFont.secondary()).foregroundStyle(.secondary)
                    linkButton("Open Credentials", "https://console.cloud.google.com/apis/credentials")
                    credentialDrop
                    credentialFields
                }

                step(4, "Connect your account") {
                    Text("Sign in through your browser. Repeat later for more accounts.")
                        .font(PMFont.secondary()).foregroundStyle(.secondary)
                    Button {
                        OAuthConfig.clientID = clientID
                        OAuthConfig.clientSecret = clientSecret
                        store.addAccount()
                    } label: {
                        Label("Connect Google Account", systemImage: "person.crop.circle.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(!configured)
                    if !configured {
                        Text("Enter a valid Client ID (ends in .apps.googleusercontent.com) and secret to continue.")
                            .font(PMFont.caption()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(PMSpacing.xl)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case let .success(url) = result { loadCredentials(from: url) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PMSpacing.xs) {
            Text("Welcome to PerfectMail")
                .font(PMFont.title())
            Text("A quick, one-time Google setup keeps your mail flowing only between this Mac and Google — no third party, including PerfectMail, ever sees it.")
                .font(PMFont.secondary()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func step(_ n: Int, _ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: PMSpacing.md) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: PMSpacing.sm) {
                Text(title).font(PMFont.body().weight(.semibold))
                content()
            }
        }
        .padding(PMSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var credentialDrop: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundStyle(.secondary.opacity(0.5))
            .frame(height: 54)
            .overlay {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc")
                    Text(importNote ?? "Drop client_secret_….json here, or click to choose")
                        .font(PMFont.caption())
                }
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { importing = true }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { loadCredentials(from: url) } }
                }
                return true
            }
    }

    private var credentialFields: some View {
        VStack(spacing: PMSpacing.sm) {
            TextField("Client ID", text: $clientID)
                .onChange(of: clientID) { OAuthConfig.clientID = clientID }
            SecureField("Client Secret", text: $clientSecret)
                .onChange(of: clientSecret) { OAuthConfig.clientSecret = clientSecret }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func linkButton(_ title: String, _ urlString: String) -> some View {
        Button {
            if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
        } label: {
            Label(title, systemImage: "arrow.up.forward.app").font(PMFont.secondary())
        }
        .buttonStyle(.bordered)
    }

    private func loadCredentials(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let creds = OAuthConfig.parseCredentialsJSON(data) else {
            importNote = "That file didn't look like a Google client JSON."
            return
        }
        clientID = creds.clientID
        clientSecret = creds.clientSecret
        OAuthConfig.clientID = creds.clientID
        OAuthConfig.clientSecret = creds.clientSecret
        importNote = "Loaded credentials ✓"
    }
}
