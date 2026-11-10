# mruby build config for Mochi browser runtime (Emscripten)
# Targets: WASM browser, no native IO/socket

MRuby::CrossBuild.new('emscripten') do |conf|
  conf.toolchain :emscripten

  # Compile flags for Emscripten
  conf.cc.flags << '-Oz'
  conf.cc.flags << '-sSUPPORT_LONGJMP=emscripten'
  conf.linker.flags << '-sSUPPORT_LONGJMP=emscripten'

  # Use custom gembox that excludes mruby-io and mruby-socket
  # to avoid HAL stub signature mismatches in the browser.
  conf.gembox 'mochi'

end
