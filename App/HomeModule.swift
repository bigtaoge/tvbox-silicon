import SwiftUI

/// The app's main module, chosen in Settings › 主界面. One module is the home
/// screen; every module can reach Settings from its own top bar to switch again.
/// The choice is saved in UserDefaults, so the app reopens on the same module.
enum HomeModule: String, CaseIterable {
    case filmTV = "filmTV"
    case music = "music"
    case novel = "novel"
    case manga = "manga"

    /// The UserDefaults key the choice is saved under.
    static let storageKey = "homeModule"

    var title: String {
        switch self {
        case .filmTV: "影视"
        case .music: "音乐"
        case .novel: "小说"
        case .manga: "漫画"
        }
    }

    var icon: String {
        switch self {
        case .filmTV: "film.fill"
        case .music: "music.note"
        case .novel: "text.book.closed.fill"
        case .manga: "book.fill"
        }
    }
}
