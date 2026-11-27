#if os(iOS)
import PlayerEngineKit
import SwiftUI
import UIKit

/// AetherEngine 最小验证页（不碰 LiveView，也不接现有直播列表）。
/// 用法：先在影匣里打开一个 Xiaoya 订阅确认正常（这时 JVM 已启动），再来这里
/// 粘贴一条山东移动频道的 URL 点播放，看三件事：MP2 有没有声音、切台要几秒、
/// 会不会闪退。URL 只存在本机（@AppStorage），不写进代码，也不上传。
struct AetherTestView: View {
    @ObservedObject private var player = PlayerEngine.shared

    @AppStorage("aetherTestURL") private var urlString = ""
    @AppStorage("aetherTestChannel1") private var channel1URL = ""
    @AppStorage("aetherTestChannel2") private var channel2URL = ""
    @AppStorage("aetherTestChannel3") private var channel3URL = ""

    @State private var firstFrameSeconds: Double = 0
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("先打开一个 Xiaoya 订阅确认正常（JVM 已启动），再来这里测试。只验证三件事：MP2 有没有声音、切台要几秒、会不会闪退。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let creationError = player.creationError {
                    Text("引擎创建失败：\(creationError)")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                PlayerEngineSurface(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 8) {
                    Text("直播 URL").font(.headline)
                    TextField("粘贴山东移动频道 URL（m3u8）", text: $urlString)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("播放") { play(urlString) }
                            .buttonStyle(.borderedProminent)
                            .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("停止") {
                            player.stop()
                            firstFrameSeconds = 0
                        }
                        .buttonStyle(.bordered)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("快捷频道（点播就是切台，看首帧用时）").font(.headline)
                    channelRow(title: "频道 1", url: $channel1URL)
                    channelRow(title: "频道 2", url: $channel2URL)
                    channelRow(title: "频道 3", url: $channel3URL)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("状态").font(.headline)
                    statusRow("状态", player.stateText)
                    if !player.phaseText.isEmpty { statusRow("阶段", player.phaseText) }
                    if !player.startupText.isEmpty { statusRow("加载进度", player.startupText) }
                    if !player.routeText.isEmpty { statusRow("路由", player.routeText) }
                    if !player.audioDeliveryText.isEmpty { statusRow("音频交付", player.audioDeliveryText) }
                    statusRow("当前时间", formatTime(player.currentTime))
                    statusRow("落后直播", String(format: "%.1f 秒", player.behindLiveSeconds))
                    statusRow("load 用时", player.loadSeconds > 0 ? String(format: "%.1f 秒", player.loadSeconds) : "—")
                    statusRow("首帧用时", firstFrameSeconds > 0 ? String(format: "%.1f 秒", firstFrameSeconds) : "—")
                    if !player.loadResultText.isEmpty { statusRow("加载结果", player.loadResultText) }
                    if !player.errorText.isEmpty { statusRow("引擎错误", player.errorText) }
                    if !player.retuneText.isEmpty { statusRow("退台", player.retuneText) }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("音频轨道（点一下切换；MP2 在这里应显示为 mp2）").font(.headline)
                    if player.audioTracks.isEmpty {
                        Text("（暂无轨道）").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(player.audioTracks) { track in
                            Button { player.selectAudioTrack(id: track.id) } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(track.name).font(.footnote)
                                        Text(track.display).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if player.activeAudioTrackId == track.id {
                                        Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("[FFmpeg] 版本行").font(.headline)
                    Text(player.ffmpegLine)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(player.ffmpegLine.contains("ERROR") ? .red : .primary)
                    Text("期望是 FFmpegBuild 的版本（文档示例：libavcodec 62.28.102, libavformat 62.6.100, …）。如果出现 ERROR 或版本号对不上，说明引擎绑到了 App 那份静态 FFmpeg，共存失败，先不要往下测播放。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("最近日志").font(.headline)
                    Text(player.logLines.isEmpty ? "（暂无）" : player.logLines.joined(separator: "\n"))
                        .font(.system(.footnote, design: .monospaced))
                }

                Button(copied ? "已复制" : "复制测试结果") {
                    UIPasteboard.general.string = summaryText
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle("AetherEngine 测试")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(player.$hasFirstFrame) { ready in
            // hasFirstFrame 在整个 load 期间保持 true，下一次 load 会先变回 false，
            // 所以只在刚点完播放、还没算出首帧时算一次。
            if ready, firstFrameSeconds == 0, let start = player.loadStartedAt,
               Date().timeIntervalSince(start) < 180 {
                firstFrameSeconds = Date().timeIntervalSince(start)
            }
        }
        .onDisappear { player.stop() }
    }

    private func channelRow(title: String, url: Binding<String>) -> some View {
        HStack {
            TextField(title + " URL", text: url)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("播") { play(url.wrappedValue) }
                .buttonStyle(.bordered)
                .disabled(url.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func play(_ url: String) {
        firstFrameSeconds = 0
        urlString = url
        Task { await player.load(urlString: url) }
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.footnote)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var summaryText: String {
        """
        AetherEngine 测试结果
        状态：\(player.stateText)
        路由：\(player.routeText)
        音频交付：\(player.audioDeliveryText)
        音频轨道：\(player.audioTracks.map { $0.display }.joined(separator: " / "))
        load 用时：\(player.loadSeconds > 0 ? String(format: "%.1f 秒", player.loadSeconds) : "—")
        首帧用时：\(firstFrameSeconds > 0 ? String(format: "%.1f 秒", firstFrameSeconds) : "—")
        \(player.ffmpegLine)
        引擎错误：\(player.errorText.isEmpty ? "无" : player.errorText)
        加载结果：\(player.loadResultText)
        """
    }
}
#endif
