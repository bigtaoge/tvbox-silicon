// PlayerEngineKit/PlayerEngine.swift
//
// AetherEngine 的薄封装：App 只和这个 framework 说话，绝不直接 import AetherEngine。
//
// 为什么要隔一层（AetherEngine docs/installation.md "FFmpeg in the same app"）：
// App 里已有一份静态 FFmpeg（TVCore 链接的 Vendor/FFmpeg），它的符号会成为可执行
// 文件里的定义；引擎如果静态链进 App，会绑定到那份 FFmpeg 而不是自己的
// FFmpegBuild，出的错看起来像引擎的 bug，其实是链错了库。所以引擎链进这个
// 动态 framework，App 只调这里的 plain-type 接口。验证命令（见交付说明）：
//   nm -m PlayerEngineKit.framework/PlayerEngineKit | grep _avcodec_open2
// 应为 (undefined) external _avcodec_open2 (from AetherLibavcodec)。
//
// 只做最小验证：建一次引擎、播直播 URL、暴露状态与 [FFmpeg] 版本行。
// 写法对照官方示例 Examples/MinimalPlayer/MinimalPlayerApp.swift 和
// Examples/LiveHost/LiveChannelHost.swift（AetherEngine 7.76.0）。

import AetherEngine
import Combine
import Foundation

/// 音频轨道（只取测试页要显示的字段；完整信息在引擎的 TrackInfo 里）。
public struct PlayerAudioTrack: Identifiable, Equatable {
    public let id: Int
    public let name: String
    public let codec: String
    public let language: String
    public let channels: Int
    public let sampleRate: Int
    public let profile: String

    /// 例如 "mp2 · 2声道 · 48000 Hz"；MP2 有没有声音，先看这里有没有这条轨道，
    /// 再用耳朵确认。
    public var display: String {
        var parts = [codec]
        if channels > 0 { parts.append("\(channels)声道") }
        if sampleRate > 0 { parts.append("\(sampleRate) Hz") }
        if !language.isEmpty { parts.append(language) }
        if !profile.isEmpty { parts.append(profile) }
        return parts.joined(separator: " · ")
    }
}

/// 引擎日志的中继。EngineLog.handler 在引擎自己的线程上回调（demuxer、producer
/// 等任意线程），绝不能直接碰 @MainActor 的状态。handler 只把行推进这个线程安全
/// 的 relay；PlayerEngine 再用 Combine 把行接回主线程显示。
final class AetherEngineLogRelay: @unchecked Sendable {
    static let shared = AetherEngineLogRelay()

    private let lock = NSLock()
    private var storedLines: [String] = []
    let subject = PassthroughSubject<String, Never>()

    func append(_ line: String) {
        lock.lock()
        storedLines.append(line)
        if storedLines.count > 200 { storedLines.removeFirst(storedLines.count - 200) }
        lock.unlock()
        subject.send(line)
    }

    func recentLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedLines
    }
}

/// 在非隔离上下文安装日志 handler：handler 的类型是普通的 `(String) -> Void`，
/// 会在引擎的任意线程上被调用，所以闭包里只能碰线程安全的 relay，绝不能碰
/// PlayerEngine（@MainActor）或任何 @Published 状态。
private func installAetherEngineLogHandler() {
    EngineLog.handler = { line in
        AetherEngineLogRelay.shared.append(line)
    }
}

/// 直播验证用的唯一引擎。App 生命周期内只建一次（引擎的设计就是一个 App 一个引擎）。
@MainActor
public final class PlayerEngine: ObservableObject {
    public static let shared = PlayerEngine()

    /// 引擎本体；创建失败时为 nil，看 creationError。
    /// internal：只有同模块的 PlayerEngineSurface 需要它，App 不碰 AetherEngine 类型。
    private(set) var engine: AetherEngine?

    /// 引擎创建失败的原因（nil = 创建成功）。
    @Published public private(set) var creationError: String?

    // 引擎状态的 plain-type 镜像（测试页只看这些，不碰 AetherEngine 类型）。
    @Published public private(set) var stateText = "未创建"
    @Published public private(set) var phaseText = ""
    @Published public private(set) var routeText = ""
    @Published public private(set) var audioDeliveryText = ""
    @Published public private(set) var errorText = ""
    @Published public private(set) var hasFirstFrame = false
    @Published public private(set) var startupText = ""
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var behindLiveSeconds: Double = 0
    @Published public private(set) var audioTracks: [PlayerAudioTrack] = []
    @Published public private(set) var activeAudioTrackId: Int?
    /// 引擎首次 init 打的那行版本信息。期望是 FFmpegBuild 的版本
    /// （文档示例：[FFmpeg] libavcodec 62.28.102, libavformat 62.6.100, ...）。
    /// 如果这里出现 ERROR，或版本号对不上，说明引擎绑到了 App 那份静态 FFmpeg，
    /// 共存失败——先不要往下测播放。
    @Published public private(set) var ffmpegLine = "（引擎尚未创建，[FFmpeg] 行还没出现）"
    @Published public private(set) var logLines: [String] = []
    /// 最近一次 load() 返回用了几秒（从点播放到 load 返回；首帧时间由测试页另算）。
    @Published public private(set) var loadSeconds: Double = 0
    /// 最近一次 load() 开始的时间（测试页用它算首帧用时）。
    @Published public private(set) var loadStartedAt: Date?
    /// 最近一次 load() 的结果文字（成功 / 失败原因 / 被取代）。
    @Published public private(set) var loadResultText = ""
    /// liveSourceReset 触发的次数。
    @Published public private(set) var liveResetCount = 0
    /// 退台 / 重试的状态文字。
    @Published public private(set) var retuneText = ""

    private var cancellables: Set<AnyCancellable> = []
    private var currentURL: URL?
    /// The headers the current URL was loaded with, so a retune reloads with the same ones.
    private var currentHeaders: [String: String] = [:]

    // 退台护栏（照抄 LiveHost 的数：一次只跑一个、间隔 20 秒、一个会话最多 3 次，
    // 否则死掉的上游会变成无限重试循环）。
    private var retuneInFlight = false
    private var retuneCount = 0
    private var lastRetuneAt: Date?

    private init() {
        // 必须在第一个引擎创建之前装 handler，否则 [FFmpeg] 行收不到。
        installAetherEngineLogHandler()
        do {
            let engine = try AetherEngine()
            // 测试页没有 AVPlayerViewController，引擎自己激活音频会话（MinimalPlayer 做法）。
            engine.nativeAudioSessionActivationEnabled = true
            self.engine = engine
            stateText = "已创建，未播放"
            subscribe(to: engine)
        } catch {
            creationError = "\(error)"
            stateText = "引擎创建失败"
        }
        subscribeToLogRelay()
    }

    // MARK: - 播放

    /// 播一个直播 URL。load() 被新 load 取代时会抛 CancellationError，那不是失败，
    /// 直接忽略（api.md "How a load ends"；LiveHost contract 3）。
    /// 返回 true = load() 正常返回（不代表已有画面，看 hasFirstFrame）。
    @discardableResult
    public func load(urlString: String) async -> Bool {
        await load(urlString: urlString, headers: [:])
    }

    /// 播一个直播 URL，带上频道要发的请求头（User-Agent / Referer / Authorization 等）。
    /// 请求头经 LoadOptions.httpHeaders 发到 playlist、每个分片和每个 AES key
    /// （AetherEngine #119；文档 quick-start 的用法）。测试页不用请求头，走上面那个。
    @discardableResult
    public func load(urlString: String, headers: [String: String]) async -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            loadResultText = "URL 无效：请粘贴 http(s) 的直播地址"
            return false
        }
        // 手动点播：退台预算重新开始（LiveHost 的 tune() 做法）。
        retuneCount = 0
        lastRetuneAt = nil
        retuneText = ""
        return await load(url: url, headers: headers)
    }

    private func load(url: URL, headers: [String: String] = [:]) async -> Bool {
        guard let engine else {
            loadResultText = "引擎未创建：\(creationError ?? "未知原因")"
            return false
        }
        currentURL = url
        currentHeaders = headers
        loadStartedAt = Date()
        loadResultText = "正在加载…"
        do {
            // 不开 nativeRemoteHLS：那是 AVPlayer 直通，AVPlayer 解不了 MP2，
            // 正是现在这条路要绕开的问题。默认路由会走到直播 ingest + 音频桥，
            // 由引擎自己的 FFmpeg 解 MP2。
            // liveJoinProfile 默认就是 .fastZap，这里写明是提醒这是切台速度的测试。
            _ = try await engine.load(url: url, options: LoadOptions(httpHeaders: headers, isLive: true, liveJoinProfile: .fastZap))
            loadSeconds = Date().timeIntervalSince(loadStartedAt ?? Date())
            loadResultText = "load() 已返回（\(String(format: "%.1f", loadSeconds)) 秒）"
            return true
        } catch is CancellationError {
            // 被新的播放取代：后继的 load 拥有这个会话，没什么可报的。
            loadResultText = "已被新的播放取代"
            return false
        } catch {
            loadSeconds = Date().timeIntervalSince(loadStartedAt ?? Date())
            loadResultText = "load() 失败：\(error.localizedDescription)"
            return false
        }
    }

    public func stop() {
        engine?.stop()
        currentURL = nil
        currentHeaders = [:]
        loadResultText = "已停止"
    }

    /// 暂停 / 继续（锁屏和耳机线的播放/暂停键用；直播暂停后继续从直播边沿播）。
    public func pause() { engine?.pause() }
    public func resume() { engine?.play() }

    public func selectAudioTrack(id: Int) {
        engine?.selectAudioTrack(index: id)
    }

    // MARK: - 退台（liveSourceReset）

    private func handleLiveSourceReset() {
        liveResetCount += 1
        guard let url = currentURL else { return }
        guard !retuneInFlight else {
            retuneText = "源端重置：上一次恢复还在进行，已跳过"
            return
        }
        let tooSoon = lastRetuneAt.map { Date().timeIntervalSince($0) < 20 } ?? false
        guard retuneCount < 3, !tooSoon else {
            retuneText = "源端重置：重试次数用完（3 次），请手动点播放"
            return
        }
        retuneInFlight = true
        retuneCount += 1
        lastRetuneAt = Date()
        retuneText = "源端重置：正在恢复…（第 \(retuneCount)/3 次）"
        Task { [weak self] in
            guard let self, let engine = self.engine else { return }
            // api.md 建议先试 retryLiveSourceRecovery()（不断 DVR 时间线），
            // 不行再用同一个 URL 重新 load（LiveHost 的做法）。
            if engine.retryLiveSourceRecovery() {
                self.retuneText = "源端重置：已恢复"
            } else {
                self.retuneText = "源端重置：恢复失败，重新加载同一频道…"
                _ = await self.load(url: url, headers: self.currentHeaders)
            }
            self.retuneInFlight = false
        }
    }

    // MARK: - 状态镜像
    //
    // 注意：这里不用 Combine 的 `.assign(to: &$x)`。Xcode 27 / Swift 6.4 下
    // `.assign(to:)` 解析出来的返回值是空元组 `()`，接不上 `.store(in:)`，
    // 14 处全报 "value of tuple type '()' has no member 'store"。
    // 改成 `.sink { [weak self] in self?.x = value }`，功能完全一样，
    // 是 Combine 里最稳的订阅写法。
    private func subscribe(to engine: AetherEngine) {
        engine.$state
            .receive(on: DispatchQueue.main)
            .map { String(describing: $0) }
            .sink { [weak self] value in self?.stateText = value }
            .store(in: &cancellables)
        engine.$playbackPhase
            .receive(on: DispatchQueue.main)
            .map { String(describing: $0) }
            .sink { [weak self] value in self?.phaseText = value }
            .store(in: &cancellables)
        engine.$videoRoute
            .receive(on: DispatchQueue.main)
            .map { String(describing: $0) }
            .sink { [weak self] value in self?.routeText = value }
            .store(in: &cancellables)
        engine.$audioDelivery
            .receive(on: DispatchQueue.main)
            .map { String(describing: $0) }
            .sink { [weak self] value in self?.audioDeliveryText = value }
            .store(in: &cancellables)
        engine.$errorInfo
            .receive(on: DispatchQueue.main)
            .map { info -> String in
                guard let info else { return "" }
                // 按 kind 分类，不要按 message 文本（message 可能是设备语言的本地化文本）。
                return "\(info.kind.rawValue): \(info.message)"
            }
            .sink { [weak self] value in self?.errorText = value }
            .store(in: &cancellables)
        engine.$hasFirstFrameReadyForDisplay
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.hasFirstFrame = value }
            .store(in: &cancellables)
        engine.$startupProgress
            .receive(on: DispatchQueue.main)
            .map { progress -> String in
                guard let progress else { return "" }
                return "\(Int(progress.fraction * 100))% · \(String(describing: progress.stage))"
            }
            .sink { [weak self] value in self?.startupText = value }
            .store(in: &cancellables)
        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.duration = value }
            .store(in: &cancellables)
        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.currentTime = value }
            .store(in: &cancellables)
        engine.clock.$behindLiveSeconds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.behindLiveSeconds = value }
            .store(in: &cancellables)
        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .map { tracks in
                tracks.map { track in
                    PlayerAudioTrack(
                        id: track.id,
                        name: track.name,
                        codec: track.codec,
                        language: track.language ?? "",
                        channels: track.channels,
                        sampleRate: track.sampleRate,
                        profile: track.profile ?? ""
                    )
                }
            }
            .sink { [weak self] value in self?.audioTracks = value }
            .store(in: &cancellables)
        engine.$activeAudioTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.activeAudioTrackId = value }
            .store(in: &cancellables)

        // 退台请求：一个引擎只订阅一次，在第一次 load 之前（LiveHost contract 1）。
        engine.liveSourceReset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handleLiveSourceReset() }
            .store(in: &cancellables)
    }

    private func subscribeToLogRelay() {
        // 引擎创建时 [FFmpeg] 行可能已经打出来了（在订阅之前），先从 relay 的缓存里补。
        let buffered = AetherEngineLogRelay.shared.recentLines()
        logLines = Array(buffered.suffix(60))
        if let ffmpeg = buffered.first(where: { $0.contains("[FFmpeg]") }) {
            ffmpegLine = ffmpeg
        }
        AetherEngineLogRelay.shared.subject
            .receive(on: DispatchQueue.main)
            .scan([String]()) { lines, line in Array((lines + [line]).suffix(60)) }
            .sink { [weak self] value in self?.logLines = value }
            .store(in: &cancellables)
        AetherEngineLogRelay.shared.subject
            .filter { $0.contains("[FFmpeg]") }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.ffmpegLine = value }
            .store(in: &cancellables)
    }
}
