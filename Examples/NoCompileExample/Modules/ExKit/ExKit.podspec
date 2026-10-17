Pod::Spec.new do |s|
  s.name = 'ExKit'
  s.version = '1.0.0'
  s.summary = 'NoCompileExample 的 Swift + ObjC 混编 UI 库（CocoaPods 版本）'
  s.homepage = 'https://example.invalid/ExKit'
  s.license = { :type => 'MIT' }
  s.author = { 'example' => 'example@example.invalid' }
  s.source = { :path => '.' }
  s.ios.deployment_target = '15.0'
  s.swift_version = '5.0'
  s.source_files = 'Public/*.h', 'Private/*.{h,m}', 'Swift/*.swift'
  s.public_header_files = 'Public/*.h'
  # 资源放进资源 bundle（ExKit.bundle），与大多数 Pod 一致
  s.resource_bundles = { 'ExKit' => ['Resources/*.{xib,strings,json}', 'Resources/ExKit.xcassets'] }
  s.dependency 'ExCore'
  s.requires_arc = true
end
