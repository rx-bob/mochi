# typed: true

module QuickJS
  module Lib
    extend FFI::Library

    # runtime.h functions
    def self.js_runtime_set_memory_limit(ctx, limit); end
    def self.js_runtime_set_max_stack_size(ctx, size); end

    # function calls
    def self.JS_Call(ctx, func_obj, this_obj, argc, argv); end
    def self.JS_CallConstructor(ctx, func_obj, argc, argv); end
    def self.JS_GetPropertyStr(ctx, this_obj, prop); end
    def self.JS_SetPropertyStr(ctx, this_obj, prop, val); end

    # JSON
    def self.JS_GetPropertyUint32(ctx, obj, idx); end
    def self.JS_ToCStringLen2(ctx, plen, val, cesu8); end
  end
end
