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
/// favourites and settings are reached from this page's top bar as icons,
/// search is the big field below, instead of the old tab bar.
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
                // The whole header is ONE principal (title-slot) item, not
                // leading/trailing toolbar items: iOS 26 wraps leading and
                // trailing toolbar items in glass pill containers, which is
                // the "框" around the source picker and the buttons. The
                // principal slot renders a custom view directly, with no
                // capsule, so the header looks like the original mockup:
                // source name on the left, four plain icons on the right.
                //
                // The navigation bar itself must stay visible: SiteView's
                // big search field lives in the navigationBarDrawer, so
                // hiding the bar would hide search too. A custom header row
                // in the page body would sit below the search field, which
                // is the wrong order — hence the principal slot, not a
                // header row.
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 16) {
                        Menu {
                            ForEach(sites) { candidate in
                                Button {
                                    sourceKey = candidate.key
                                } label: {
                                    Label(candidate.name, systemImage: candidate.key == site.key ? "checkmark" : "play.rectangle.fill")
                                }
                            }
                        } label: {
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
                        Spacer()
                        // Plain icons, as in the original mockup: TV for live,
                        // clock for history, heart for favourites, gear for
                        // settings. Icon-only buttons need accessibility labels.
                        Group {
                            Button { open(.live) } label: {
                                Image(systemName: "tv")
                            }
                            .accessibilityLabel(L10n.text("Live TV"))
                            Button { open(.history) } label: {
                                Image(systemName: "clock")
                            }
                            .accessibilityLabel(L10n.text("Playback History"))
                            Button { open(.favorites) } label: {
                                Image(systemName: "heart")
                            }
                            .accessibilityLabel(L10n.text("Favorites"))
                            Button { open(.settings) } label: {
                                Image(systemName: "gear")
                            }
                            .accessibilityLabel(L10n.text("Settings"))
                        }
                        .font(.title3)
                    }
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
