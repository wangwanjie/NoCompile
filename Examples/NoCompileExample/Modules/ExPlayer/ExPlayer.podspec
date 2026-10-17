Pod::Spec.new do |s|
  s.name = 'ExPlayer'
  s.version = '1.0.0'
  s.summary = 'NoCompileExample 的 ObjC++/C++/C 库（CocoaPods 版本）'
  s.homepage = 'https://example.invalid/ExPlayer'
  s.license = { :type => 'MIT' }
  s.author = { 'example' => 'example@example.invalid' }
  s.source = { :path => '.' }
  s.ios.deployment_target = '15.0'
  s.source_files = 'Public/*.h', 'Sources/*.{h,hpp,c,cpp,mm}'
  s.public_header_files = 'Public/*.h'
  s.static_framework = true
  s.library = 'c++'
  s.pod_target_xcconfig = { 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17' }
  s.requires_arc = true
end
