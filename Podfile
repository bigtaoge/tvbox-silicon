# 影匣Pro 直播用 VLCKit（MobileVLCKit 3.7.5，LGPLv2.1+）
# 只给 iOS 直播用；点播仍走 AVPlayer。
# 必须用动态链接（use_frameworks! 默认动态）：应用自带的 FFmpeg 是静态链接
# （TVCore 的 binaryTarget），MobileVLCKit 内含另一份 libav*，
# 静态链接会在链接期报 av_* 重复符号。
# Podfile.lock 由第一次 pod install 生成，提交进仓库锁定版本。
#
# 懒加载（2026-11-26）：框架在包里，但启动时不加载——dyld 一加载它，
# 进程内嵌的运行环境（跑 jar 的 JVM、跑音乐脚本的 QuickJS）就会被挤坏，
# 拉订阅、播点播都会闪退，即使 VLC 的代码一行都不跑。App 只在打开直播时
# 才 dlopen 它（App/VLCLivePlayer.swift 的 VLCRuntime）。所以这里去掉链接、
# 只保留嵌入：post_install 把 -framework "MobileVLCKit" 从生成的 xcconfig
# 里删掉，"[CP] Embed Pods Frameworks" 仍会把它拷进包里。
platform :ios, '17.0'
use_frameworks!

target 'TVBox-iOS' do
  pod 'MobileVLCKit', '3.7.5'
end

post_install do |installer|
  # Embed MobileVLCKit but do not link it: the app dlopens it on demand
  # (see VLCLivePlayer.swift). Removing the -framework flag from the
  # generated xcconfigs keeps dyld from loading it at launch; the
  # "[CP] Embed Pods Frameworks" phase still copies it into the bundle.
  # The workflow verifies both halves after the archive (embedded, not linked).
  # The ** glob is deliberate: the Pods target is "Pods-TVBox-iOS", so its
  # support files live under "Pods/Target Support Files/Pods-TVBox-iOS/"
  # (not "TVBox-iOS/"). The old "TVBox-iOS" glob silently matched nothing
  # (2026-11-27) and the app still linked the framework, failing the
  # verify step. Fail loudly here instead, so a future layout change
  # breaks pod install with a clear message rather than the archive.
  configs = Dir.glob("Pods/Target Support Files/**/Pods-TVBox-iOS.*.xcconfig")
  raise "post_install: no Pods-TVBox-iOS xcconfig found to strip MobileVLCKit from" if configs.empty?
  configs.each do |path|
    text = File.read(path)
    next unless text.include?("MobileVLCKit")
    stripped = text.gsub(/\s*-framework\s+"?MobileVLCKit"?/, "")
    File.write(path, stripped)
    raise "post_install: could not strip -framework MobileVLCKit from #{path}" if stripped.match?(/-framework\s+"?MobileVLCKit"?/)
  end
end
