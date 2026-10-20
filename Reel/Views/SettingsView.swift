import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var debrid: DebridService

    var body: some View {
        List {
            Section {
                NavigationLink { AddonsView() } label: {
                    Label("Add-ons", systemImage: "puzzlepiece.extension")
                        .badge(addons.addons.count)
                }
                NavigationLink { DebridSettingsView() } label: {
                    Label("Debrid account", systemImage: "key")
                        .badge(debrid.hasKey ? debrid.provider.rawValue : "Off")
                }
            }
            Section("About") {
                Text("Reel plays streams from Stremio-compatible add-ons you choose. It includes no content sources of its own.")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
            }
        }
        .navigationTitle("Settings")
    }
}

struct AddonsView: View {
    @EnvironmentObject private var addons: AddonStore
    @State private var newURL = ""
    @State private var installing = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                TextField("https://…/manifest.json or stremio://…", text: $newURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { Task { await install() } }
                Button {
                    Task { await install() }
                } label: {
                    if installing { ProgressView() } else { Text("Install add-on") }
                }
                .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty || installing)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } footer: {
                Text("Paste the add-on's manifest link. Configured add-on links (with your settings in the URL) work too.")
            }

            Section("Installed") {
                ForEach(addons.addons) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.manifest.name).font(.subheadline.weight(.semibold))
                        Text(capabilities(a)).font(.caption).foregroundStyle(.secondary)
                        Text(a.transportUrl).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .onDelete { addons.remove(at: $0) }
                .onMove { addons.move(from: $0, to: $1) }
            }
        }
        .navigationTitle("Add-ons")
        .toolbar { EditButton() }
        .refreshable { await addons.refreshAll() }
    }

    private func capabilities(_ a: InstalledAddon) -> String {
        let names = (a.manifest.resources ?? []).map(\.name)
        let catalogs = a.manifest.catalogs?.count ?? 0
        var parts = names.map { $0 == "catalog" ? "\(catalogs) catalog(s)" : $0 }
        if parts.isEmpty, catalogs > 0 { parts = ["\(catalogs) catalog(s)"] }
        return parts.joined(separator: " · ")
    }

    private func install() async {
        installing = true
        defer { installing = false }
        do {
            try await addons.install(newURL)
            newURL = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DebridSettingsView: View {
    @EnvironmentObject private var debrid: DebridService
    @State private var key = ""
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                Picker("Service", selection: $debrid.provider) {
                    ForEach(DebridProvider.allCases) { Text($0.rawValue).tag($0) }
                }
                SecureField(debrid.hasKey ? "Key saved. Paste to replace" : "API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save key") {
                    debrid.setKey(key)
                    key = ""
                    Task { await check() }
                }
                .disabled(key.isEmpty)
                Link("Get your API key", destination: debrid.provider.keyPageURL)
            } footer: {
                Text("Stored in the iPhone Keychain. Used to show your account and play files from your own account (Library → My files).")
            }

            if debrid.hasKey {
                Section("Account") {
                    if checking {
                        ProgressView()
                    } else if let a = debrid.account {
                        LabeledContent("User", value: a.username)
                        LabeledContent("Premium", value: a.premium ? "Yes" : "No")
                        if let e = a.expires { LabeledContent("Until", value: e.formatted(date: .abbreviated, time: .omitted)) }
                    } else if let err = debrid.lastError {
                        Text(err).foregroundStyle(.red)
                    }
                    Button("Check again") { Task { await check() } }
                    Button("Remove key", role: .destructive) { debrid.setKey(nil) }
                }
            }
        }
        .navigationTitle("Debrid account")
        .task { if debrid.hasKey && debrid.account == nil { await check() } }
        .onChange(of: debrid.provider) { _ in Task { if debrid.hasKey { await check() } } }
    }

    private func check() async {
        checking = true
        await debrid.refreshAccount()
        checking = false
    }
}
