# Reel

A Stremio-style media app for iPhone and iPad (iOS 16+), in SwiftUI.

- **Add-ons:** install any Stremio add-on by its manifest link (`https://…/manifest.json` or `stremio://…`).
  Catalogs show up as rows on Home, search covers every add-on that supports it, and detail pages list
  seasons and episodes. Cinemeta (metadata) and OpenSubtitles v3 (subtitles) are installed by default.
  Neither provides streams; streams come only from add-ons you add.
- **Player:** VLC (MobileVLCKit) plays MKV, HEVC, AC3/DTS/TrueHD and embedded subtitles. It has audio
  and subtitle track menus, add-on subtitles by language, ±10/30 s skip, and resumes where you stopped.
  Long-press a stream for *Play with Apple player* (AirPlay to an Apple TV), *Open in VLC / Infuse*, or *Copy link*.
- **Library:** save titles with **+**. "Continue watching" on Home shows anything you stopped part-way.
- **Debrid:** a Real-Debrid or AllDebrid API key, stored in the Keychain. Shows your account status and
  **Library → My files** plays files from your own account. Configured add-on links that include a debrid key work as usual.
- **Not included:** torrent streaming. Results that are torrents only (no direct link) are hidden and counted.

## Getting the app on your iPhone

Every push to `main` builds `Reel.ipa` on GitHub Actions (macOS runner) and attaches it to the
**latest** release (Releases → Latest build).

1. Open the repo's **Releases** page on your iPhone and download `Reel.ipa`.
2. Install it with **SideStore** (or AltStore, or iloader → SideStore): *My Apps → +* and pick the IPA.
3. With a free Apple ID the app must be refreshed every 7 days (SideStore does this), and a free
   account can have 3 sideloaded apps at once.

To build manually on a Mac: `brew install xcodegen && xcodegen generate && pod install`, then open
`Reel.xcworkspace` in Xcode.

## Layout

```
project.yml              XcodeGen project (the .xcodeproj is generated, not committed)
Podfile                  MobileVLCKit
.github/workflows/       CI: build + publish the IPA
Reel/Models/Stremio.swift       add-on protocol models (lenient decoding)
Reel/Services/AddonClient.swift /manifest, /catalog, /meta, /stream, /subtitles requests
Reel/Services/AddonStore.swift  installed add-ons
Reel/Services/LibraryStore.swift library + watch progress (Application Support/library.json)
Reel/Services/Debrid.swift      Keychain, Real-Debrid / AllDebrid
Reel/Player/                    VLC player model + full-screen player UI, Apple player
Reel/Views/                     Home, Detail, Streams, Search, Library, Settings
```
