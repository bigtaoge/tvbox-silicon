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
/// The old tab bar is gone on iOS (see `RootView`): live TV, history,
/// favourites and settings are reached from this page's top bar as text
/// buttons, search is the big field below, instead of the old tab bar.
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
                        // A plain HStack, not a Label: iOS 26 renders toolbar
                        // Labels icon-only, so the selected source's name
                        // would disappear and only the chevron would show.
                        // The name is capped: a long source name (e.g. with
                        // an emoji and a "| 4K弹幕" tag) used to eat the whole
                        // bar and push the action buttons into the "..."
                        // overflow menu. It now truncates with "..." instead.
                        HStack(spacing: 4) {
                            Text(site.name)
                                .frame(maxWidth: 120, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "chevron.down")
                        }
                        .font(.headline)
                    }
                    .accessibilityIdentifier("vertical-home.source-picker")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Compact text buttons: small font, so all four fit in
                    // the bar without iOS collapsing any of them into the
                    // "..." overflow menu. "历史" is 历史记录 shortened to
                    // save two characters of width.
                    //
                    // Do NOT wrap these four buttons in an HStack: iOS 26
                    // treats the HStack as one indivisible toolbar item and
                    // shoves the whole thing into the "..." menu, where it
                    // cannot display at all (that is what happened in the
                    // previous build: all four buttons vanished and the "..."
                    // would not open). A Group applies the font without
                    // merging the buttons, so each stays its own item.
                    Group {
                        Button { open(.live) } label: { Text(L10n.text("Live TV")) }
                        Button { open(.history) } label: { Text("历史") }
                        Button { open(.favorites) } label: { Text(L10n.text("Favorites")) }
                        Button { open(.settings) } label: { Text(L10n.text("Settings")) }
                    }
                    .font(.subheadline)
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
