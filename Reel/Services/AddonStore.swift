import Foundation

/// One catalog of one add-on.
struct CatalogRef: Identifiable {
    let addon: InstalledAddon
    let catalog: CatalogDef
    var id: String { addon.id + "|" + catalog.identity }
}

/// The installed add-ons, in order, saved between launches.
@MainActor
final class AddonStore: ObservableObject {
    /// Official Stremio add-ons for movie/series information and subtitles. They provide no streams:
    /// streams come only from add-ons you add yourself.
    static let defaults = [
        "https://v3-cinemeta.strem.io/manifest.json",
        "https://opensubtitles-v3.strem.io/manifest.json",
    ]

    @Published private(set) var addons: [InstalledAddon] = []
    @Published var lastError: String?

    private let key = "installedAddons.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([InstalledAddon].self, from: data) {
            addons = saved
        } else {
            Task { await installDefaults() }
        }
    }

    func installDefaults() async {
        for url in Self.defaults where !addons.contains(where: { $0.transportUrl == url }) {
            try? await install(url)
        }
    }

    func install(_ input: String) async throws {
        let addon = try await AddonClient.shared.fetchManifest(input)
        if let i = addons.firstIndex(where: { $0.transportUrl == addon.transportUrl }) {
            addons[i] = addon // refresh
        } else {
            addons.append(addon)
        }
        save()
    }

    func remove(at offsets: IndexSet) {
        addons.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        addons.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Re-download every manifest (add-ons add catalogs over time).
    func refreshAll() async {
        for addon in addons {
            try? await install(addon.transportUrl)
        }
    }

    func supporting(_ resource: String, type: String, id: String) -> [InstalledAddon] {
        addons.filter { $0.manifest.supports(resource, type: type, id: id) }
    }

    /// Catalog rows for the home screen: every catalog that needs no extra input.
    var homeCatalogs: [CatalogRef] {
        addons.flatMap { addon in
            (addon.manifest.catalogs ?? []).filter { !$0.hasRequiredExtra }.map { CatalogRef(addon: addon, catalog: $0) }
        }
    }

    var searchCatalogs: [CatalogRef] {
        addons.flatMap { addon in
            (addon.manifest.catalogs ?? []).filter { $0.supportsSearch && !$0.needsNonSearchExtra }
                .map { CatalogRef(addon: addon, catalog: $0) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(addons) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
