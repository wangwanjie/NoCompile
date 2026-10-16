#
# NoCompile 客户端的 CocoaPods 描述文件
#
# 只应在 Debug 配置引入：
#   pod 'NoCompile', :configurations => ['Debug']
#
# 客户端代码由 DEBUG 宏控制（CocoaPods 会给 Debug 配置的 Pod target 定义 DEBUG=1）。
# 其他配置名（如 Dev）也想启用时，在 Podfile 里用 project 'App', 'Dev' => :debug 声明为 debug 类型。
#
Pod::Spec.new do |s|
  s.name         = 'NoCompile'
  # 与 App/project.yml 的 MARKETING_VERSION 保持一致，发布时打 v<版本号> 的 tag
  s.version      = '0.2.1'
  s.summary      = 'iOS / macOS 热重载客户端，支持 C、C++、Objective-C、Swift。'
  s.description  = <<-DESC
    NoCompile 只重新编译改动的文件并注入运行中的 App。本 Pod 是 App 进程内的客户端，
    需配合 NoCompile.app（菜单栏 App）或 nocompile 命令行工具使用。
  DESC
  s.homepage     = 'https://github.com/wangwanjie/NoCompile'
  s.license      = { :type => 'MIT', :file => 'LICENSE' }
  s.author       = { 'wangwanjie' => 'https://github.com/wangwanjie' }
  s.source       = { :git => 'https://github.com/wangwanjie/NoCompile.git', :tag => "v#{s.version}" }

  s.ios.deployment_target  = '15.0'
  s.osx.deployment_target  = '12.0'
  s.tvos.deployment_target = '15.0'

  s.source_files         = 'Sources/NoCompileClient/**/*.{h,m}'
  s.public_header_files  = 'Sources/NoCompileClient/include/NoCompile.h'
  s.requires_arc         = true

  s.frameworks      = 'Foundation'
  s.ios.frameworks  = 'UIKit'
  s.tvos.frameworks = 'UIKit'
  s.osx.frameworks  = 'AppKit'

  # 客户端源文件里用引号 #import "NoCompile.h"，公开头文件位于 include/ 子目录
  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/Sources/NoCompileClient/include"',
  }

  # 热重载必需：让宿主 App 内部的函数调用走符号指针。
  # 该设置只会合并进引入了本 Pod 的那些配置（即 :configurations 指定的 Debug），不会影响 Release。
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -Xlinker -interposable',
  }
end
