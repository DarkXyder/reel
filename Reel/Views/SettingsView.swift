import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var debrid: DebridService
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var trakt: TraktService

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
                NavigationLink { TraktSettingsView() } label: {
                    Label("Trakt", systemImage: "arrow.triangle.2.circlepath")
                        .badge(trakt.username ?? (trakt.isConnected ? "On" : "Off"))
                }
                NavigationLink { StorageView() } label: {
                    Label("Storage & downloads", systemImage: "internaldrive")
                }
            }

            Section("Appearance") {
                Picker("Mode", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.rawValue).tag($0) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Accent colour")
                    HStack(spacing: 12) {
                        ForEach(AccentChoice.allCases) { c in
                            Button { settings.accent = c } label: {
                                Circle().fill(c.color).frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: settings.accent == c ? 2.5 : 0).padding(-4))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(c.rawValue)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Picker("Player", selection: $settings.playerMode) {
                    ForEach(PlayerMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Play next episode automatically", isOn: $settings.autoPlayNext)
                Toggle("Keep sound playing in the background", isOn: $settings.backgroundAudio)
                Stepper(value: $settings.skipIntroSeconds, in: 0...300, step: 5) {
                    LabeledContent("Skip intro jumps", value: settings.skipIntroSeconds == 0 ? "Off" : "\(settings.skipIntroSeconds) s")
                }
                Picker("Sort streams by", selection: $settings.streamSort) {
                    ForEach(StreamSort.allCases) { Text($0.rawValue).tag($0) }
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("Auto uses Apple's player (AirPlay video, picture-in-picture) for MP4 and HLS streams and VLC for everything else, such as MKV.")
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

struct TraktSettingsView: View {
    @EnvironmentObject private var trakt: TraktService
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var addons: AddonStore
    @State private var secret = ""
    @State private var importing = false
    @State private var imported: Int?

    var body: some View {
        Form {
            if trakt.isConnected {
                Section("Account") {
                    LabeledContent("Signed in as", value: trakt.username ?? "Trakt user")
                    Button {
                        Task {
                            importing = true
                            imported = await trakt.importProgress(into: library, addons: addons)
                            importing = false
                        }
                    } label: {
                        if importing { ProgressView() } else { Text("Import progress from Trakt") }
                    }
                    if let imported { Text("Imported \(imported) item(s).").font(.caption).foregroundStyle(.secondary) }
                    Button("Disconnect", role: .destructive) { trakt.disconnect() }
                }
                Section {
                    Text("What you watch is sent to Trakt as you play it, and Trakt marks it watched past 80 %. Progress from your other devices is imported when Reel opens.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if let code = trakt.pendingCode {
                Section("Approve on Trakt") {
                    Text("Go to").font(.subheadline)
                    Link(code.verification_url, destination: URL(string: code.verification_url) ?? URL(string: "https://trakt.tv/activate")!)
                    Text("and enter this code:").font(.subheadline)
                    Text(code.user_code).font(.system(size: 34, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    HStack { ProgressView(); Text("Waiting for approval…").foregroundStyle(.secondary) }
                    Button("Cancel", role: .cancel) { trakt.cancelConnect() }
                }
            } else {
                Section {
                    TextField("Client ID", text: $trakt.clientId)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(trakt.clientSecret.isEmpty ? "Client Secret" : "Secret saved. Paste to replace", text: $secret)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save and connect") {
                        if !secret.isEmpty { trakt.setSecret(secret); secret = "" }
                        Task { await trakt.connect() }
                    }
                    .disabled(trakt.clientId.isEmpty || (trakt.clientSecret.isEmpty && secret.isEmpty))
                    if let s = trakt.status { Text(s).font(.caption).foregroundStyle(.red) }
                } header: {
                    Text("Your Trakt API app")
                } footer: {
                    Text("Trakt needs an API app of your own (free): open trakt.tv/oauth/applications/new, enter any name, set Redirect URI to urn:ietf:wg:oauth:2.0:oob, save, and paste the Client ID and Client Secret here.")
                }
                Section { Link("Create a Trakt API app", destination: URL(string: "https://trakt.tv/oauth/applications/new")!) }
            }
        }
        .navigationTitle("Trakt")
    }
}

/// Where downloads go, how much space they use, and clean-up.
struct StorageView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var picking = false
    @State private var confirmDeleteAll = false
    @State private var cacheBytes = URLCache.shared.currentDiskUsage
    @State private var pickError: String?

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Save to", value: FolderAccess.name(settings.downloadFolderBookmark))
                Button("Choose a folder in Files…") { picking = true }
                if settings.downloadFolderBookmark != nil {
                    Button("Use Reel’s own folder") { settings.downloadFolderBookmark = nil }
                }
                if let pickError { Text(pickError).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Download location")
            } footer: {
                Text("Reel’s own folder is in the Files app under On My iPhone → Reel → Downloads. A chosen folder can be on iCloud Drive or a USB drive. New downloads go there; existing ones stay where they are.")
            }

            Section("Space") {
                LabeledContent("Downloads", value: bytes(downloads.totalSize))
                if let free = DownloadManager.freeSpace { LabeledContent("Free on this iPhone", value: bytes(free)) }
                LabeledContent("Image cache", value: bytes(Int64(cacheBytes)))
                Button("Clear image cache") {
                    URLCache.shared.removeAllCachedResponses()
                    cacheBytes = URLCache.shared.currentDiskUsage
                }
            }

            Section {
                Toggle("Delete downloads after watching", isOn: $settings.deleteWatchedDownloads)
                let watched = downloads.watchedDownloads(library)
                Button("Delete watched downloads (\(watched.count))") { watched.forEach(downloads.delete) }
                    .disabled(watched.isEmpty)
                Button("Delete all downloads", role: .destructive) { confirmDeleteAll = true }
                    .disabled(downloads.records.isEmpty)
            } footer: {
                Text("A video counts as watched once you've seen 92 % of it.")
            }

            if !downloads.records.isEmpty {
                Section("Largest downloads") {
                    ForEach(downloads.records.sorted { downloads.fileSize($0) > downloads.fileSize($1) }.prefix(20)) { r in
                        HStack {
                            Text(r.displayTitle).lineLimit(1)
                            Spacer()
                            Text(bytes(downloads.fileSize(r))).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.subheadline)
                        .swipeActions { Button(role: .destructive) { downloads.delete(r) } label: { Label("Delete", systemImage: "trash") } }
                    }
                }
            }
        }
        .navigationTitle("Storage & downloads")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                if let data = FolderAccess.bookmark(for: url) {
                    settings.downloadFolderBookmark = data
                    pickError = nil
                } else {
                    pickError = "Couldn't get access to that folder."
                }
            case .failure(let e):
                pickError = e.localizedDescription
            }
        }
        .confirmationDialog("Delete all downloads?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { downloads.deleteAll() }
        }
    }
}
