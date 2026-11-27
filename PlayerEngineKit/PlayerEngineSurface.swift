// PlayerEngineKit/PlayerEngineSurface.swift
//
// 播放画面：把引擎的 AetherPlayerSurface 包一层，让 App 不用碰 AetherEngine 类型。
// 引擎还没建出来（创建失败）时显示黑底。

import AetherEngine
import SwiftUI

public struct PlayerEngineSurface: View {
    private let player: PlayerEngine

    public init(player: PlayerEngine) {
        self.player = player
    }

    public var body: some View {
        if let engine = player.engine {
            AetherPlayerSurface(engine: engine)
        } else {
            Color.black
        }
    }
}
