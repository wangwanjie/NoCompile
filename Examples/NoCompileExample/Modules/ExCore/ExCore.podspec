Pod::Spec.new do |s|
  s.name = 'ExCore'
  s.version = '1.0.0'
  s.summary = 'NoCompileExample 的 ObjC + C 基础库（CocoaPods 版本）'
  s.homepage = 'https://example.invalid/ExCore'
  s.license = { :type => 'MIT' }
  s.author = { 'example' => 'example@example.invalid' }
  s.source = { :path => '.' }
  s.ios.deployment_target = '15.0'
  s.source_files = 'Public/*.h', 'Private/*.{h,m,c}'
  s.public_header_files = 'Public/*.h'
  s.requires_arc = true
end
