#if os(iOS)
import SwiftUI
import TVCore

/// Step 2 of the vertical TVBox rebuild: the single-page vertical home.
///
/// The page is deliberately thin: it picks the current source (the same
/// "recommendationSource" choice and strategy order Watch Now used) and hands
/// the whole browse surface to the existing `SiteView`, which already is the
/// vertical TVBox layout — a horizontal category chip row over a poster grid
/// that loads the next page at the bottom. Search, categories, pagination,
/// detail and episode picking all stay exactly as `SiteView` does them.
///
/// The old tab bar is gone on iOS (see `RootView`): search, live TV, history,
/// favourites and settings are reached from this page's top bar instead, as
/// pages pushed on this page's own stack.
struct VerticalTVBoxHomeView: View {
    @Environment(Store.self) private var store
    @Environment(\.openRoute) private var openRoute
    @AppStorage("recommendationSource") private var sourceKey = ""

    private var sites: [Site] {
        guard let config = store.subscription else { return [] }
        return store.recommendationSites(config)
    }

    /// Until the viewer picks a source, the first in strategy order, passing
    /// over a source paused for failing — the same rule `RecommendationsView`
    /// used, so opening the app does not start the JVM when a standard API or
    /// script source is available.
    private var site: Site? {
        guard let config = store.subscription else { return nil }
        return sites.first(where: { $0.key == sourceKey })
            ?? sites.first(where: { !SourceHealth.shared.paused($0, origin: config.origin) })
            ?? sites.first
    }

    var body: some View {
        Group {
            if let config = store.subscription, let site {
                // Keyed by source: switching source must rebuild `SiteView`'s
                // browser state instead of reusing the previous source's list.
                SiteView(site: site, origin: config.origin, jarURL: config.spiderURL)
                    .id(site.key + "|" + config.origin.absoluteString)
            } else {
                ContentUnavailableView {
                    Label(L10n.text("No Subscription"), systemImage: "square.grid.2x2.fill")
                } description: {
                    Text(L10n.text("Add a TVBox subscription to start watching."))
                } actions: {
                    Button(L10n.text("Add Subscription")) { open(.settings) }
                }
            }
        }
        .toolbar {
            if let site, !sites.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(sites) { candidate in
                            Button {
                                sourceKey = candidate.key
                            } label: {
                                Label(candidate.name, systemImage: candidate.key == site.key ? "checkmark" : "play.rectangle.fill")
                            }
                        }
                    } label: {
                        Label(site.name, systemImage: "chevron.down")
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .accessibilityIdentifier("vertical-home.source-picker")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { open(.search) } label: { Label(L10n.text("Global Search"), systemImage: "magnifyingglass") }
                    Button { open(.live) } label: { Label(L10n.text("Live TV"), systemImage: "dot.radiowaves.left.and.right") }
                    Button { open(.history) } label: { Label(L10n.text("Playback History"), systemImage: "clock.arrow.circlepath") }
                    Button { open(.favorites) } label: { Label(L10n.text("Favorites"), systemImage: "heart.fill") }
                    Button { open(.settings) } label: { Label(L10n.text("Settings"), systemImage: "slider.horizontal.3") }
                }
            }
        }
        .screenBackdrop()
    }

    private func open(_ section: AppSection) {
        openRoute?(Route { AnyView(SectionPage(section: section)) })
    }
}
#endif
