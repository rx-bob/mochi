# Ultra-minimal mruby build — only what UI components actually need
MRuby::CrossBuild.new('emscripten') do |conf|
  conf.toolchain :emscripten

  conf.cc.flags << '-Oz'

  # Only the extensions components actually use
  conf.gem core: 'mruby-string-ext'    # String#include?, interpolation extras
  conf.gem core: 'mruby-array-ext'     # Array#map, #select, #each, #last, etc.
  conf.gem core: 'mruby-hash-ext'      # Hash extensions
  conf.gem core: 'mruby-enum-ext'      # Enumerable#map, #select, etc.
  conf.gem core: 'mruby-numeric-ext'   # Integer methods
  conf.gem core: 'mruby-object-ext'    # Object extensions
  conf.gem core: 'mruby-kernel-ext'    # Kernel extensions
  conf.gem core: 'mruby-sprintf'       # String interpolation uses this
  conf.gem core: 'mruby-error'         # begin/rescue
  conf.gem core: 'mruby-toplevel-ext'  # toplevel methods
  conf.gem core: 'mruby-compar-ext'    # Comparable
  conf.gem core: 'mruby-catch'         # catch/throw

  # NO compiler — bytecode is pre-compiled
  # NO regexp — not needed for basic components
  # NO fiber/enumerator — not needed
  # NO time/struct/set/objectspace/random/pack — not needed
  # NO metaprog/eval/binding — not needed
end

# Host build for mrbc (bytecode compiler runs natively)
MRuby::Build.new do |conf|
  conf.toolchain :clang
  conf.gem core: 'mruby-compiler'
  conf.gem core: 'mruby-bin-mrbc'
end
