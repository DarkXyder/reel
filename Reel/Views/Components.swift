import SwiftUI

/// A poster with a soft placeholder while loading.
struct PosterImage: View {
    let url: String?
    var landscape = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06))
            if let s = url, let u = URL(string: s) {
                AsyncImage(url: u, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else if phase.error != nil {
                        Image(systemName: "film").font(.title).foregroundStyle(.tertiary)
                    } else {
                        Color.clear
                    }
                }
            } else {
                Image(systemName: "film").font(.title).foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(landscape ? 16.0 / 9.0 : 2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// Saved-progress bar along the bottom of a thumbnail; a checkmark once watched.
struct ProgressOverlay: View {
    let progress: VideoProgress?

    var body: some View {
        if let p = progress, p.fraction > 0.01 {
            ZStack(alignment: .bottomLeading) {
                if p.isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.55))
                        Capsule().fill(Color.accentColor).frame(width: max(4, g.size.width * p.fraction))
                    }
                }
                .frame(height: 4)
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            // Fill the whole thumbnail so the bar sits on its bottom edge, not in the middle.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .allowsHitTesting(false)
        }
    }
}

struct PosterCard: View {
    let meta: MetaPreview
    var width: CGFloat = 112
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: meta.poster).frame(width: width)
                .overlay(ProgressOverlay(progress: meta.type == "series" ? nil
                                         : library.progress(metaId: meta.id, videoId: meta.id)))
            Text(meta.name).font(.caption).lineLimit(1).frame(width: width, alignment: .leading)
        }
    }
}

/// Wide card with a progress bar, for "Continue watching".
struct ContinueCard: View {
    let entry: LibraryEntry
    var width: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                PosterImage(url: entry.background ?? entry.poster, landscape: true).frame(width: width)
                    .overlay(ProgressOverlay(progress: VideoProgress(position: entry.position, duration: entry.duration,
                                                                     updatedAt: entry.updatedAt)))
            }
            .frame(width: width)
            Text(entry.name).font(.caption.weight(.semibold)).lineLimit(1)
            if let t = entry.lastVideoTitle {
                Text(t).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.horizontal)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}
