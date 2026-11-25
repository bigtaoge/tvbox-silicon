# 影匣Pro 直播用 VLCKit（MobileVLCKit 3.7.5，LGPLv2.1+）
# 只给 iOS 直播用；点播仍走 AVPlayer。
# 必须用动态链接（use_frameworks! 默认动态）：应用自带的 FFmpeg 是静态链接
# （TVCore 的 binaryTarget），MobileVLCKit 内含另一份 libav*，
# 静态链接会在链接期报 av_* 重复符号。
# Podfile.lock 由第一次 pod install 生成，提交进仓库锁定版本。
platform :ios, '17.0'
use_frameworks!

target 'TVBox-iOS' do
  pod 'MobileVLCKit', '3.7.5'
end
