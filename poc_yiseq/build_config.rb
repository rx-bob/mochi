# Minimal mruby build for Mochi PoC — Emscripten cross-compile
MRuby::CrossBuild.new('emscripten') do |conf|
  conf.toolchain :emscripten

  conf.cc.flags << '-Oz'

  # Core stdlib (no IO, no socket, no bin tools)
  conf.gembox "stdlib"
  conf.gembox "stdlib-ext"

  # Compiler needed for eval
  conf.gem core: 'mruby-compiler'
  conf.gem core: 'mruby-error'
  conf.gem core: 'mruby-method'

  # Metaprogramming
  conf.gembox "metaprog"
end

# Host build for mrbc (bytecode compiler runs natively)
MRuby::Build.new do |conf|
  conf.toolchain :clang
  conf.gem core: 'mruby-compiler'
  conf.gem core: 'mruby-bin-mrbc'
end
