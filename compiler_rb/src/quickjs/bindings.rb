# typed: false
# frozen_string_literal: true

require "ffi"
require "sorbet-runtime"

# Low-level FFI bindings to the QuickJS C library.
# Ported from compiler/src/js/qjs_bindings.cr
module QuickJSBindings
  extend FFI::Library

  # Try multiple candidate paths for the QuickJS library
  CANDIDATE_DIRS = T.let([
    File.expand_path("../../../fragments/libs", __dir__),
    File.expand_path("../../fragments/libs", __dir__),
    File.expand_path("../fragments/libs", __dir__),
    "/usr/local/lib",
    "/opt/homebrew/lib",
  ].freeze, T::Array[String])

  def self.find_lib(name)
    extensions = [".dylib", ".so", ".dll"]
    CANDIDATE_DIRS.each do |dir|
      extensions.each do |ext|
        path = File.join(dir, "lib#{name}#{ext}")
        return path if File.exist?(path)
      end
    end
    # fallback: let ffi_lib try to resolve it system-wide
    name
  end

  ffi_lib find_lib("qjs")

  # JSValue is a 16-byte struct: union (8 bytes) + tag (8 bytes)
  # On 64-bit platforms without NAN boxing:
  #   u_int32      : int32  (low 32 bits of union)
  #   u_float64_low: int32  (high 32 bits of union)
  #   tag          : int64
  class JSValue < FFI::Struct
    layout :u_int32, :int32,
           :u_float64_low, :int32,
           :tag, :int64
  end

  # -- Constants for JSValue tags --
  JS_TAG_FIRST             = -9
  JS_TAG_BIG_INT           = -9
  JS_TAG_SYMBOL            = -8
  JS_TAG_STRING            = -7
  JS_TAG_MODULE            = -3
  JS_TAG_FUNCTION_BYTECODE = -2
  JS_TAG_OBJECT            = -1
  JS_TAG_INT               =  0
  JS_TAG_BOOL              =  1
  JS_TAG_NULL              =  2
  JS_TAG_UNDEFINED         =  3
  JS_TAG_UNINITIALIZED     =  4
  JS_TAG_CATCH_OFFSET      =  5
  JS_TAG_EXCEPTION         =  6
  JS_TAG_SHORT_BIG_INT     =  7
  JS_TAG_FLOAT64           =  8

  # -- Property flags --
  JS_PROP_CONFIGURABLE = 1 << 0
  JS_PROP_WRITABLE       = 1 << 1
  JS_PROP_ENUMERABLE     = 1 << 2
  JS_PROP_C_W_E          = JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE | JS_PROP_ENUMERABLE

  # -- Eval flags --
  JS_EVAL_TYPE_GLOBAL            = 0 << 0
  JS_EVAL_TYPE_MODULE            = 1 << 0
  JS_EVAL_FLAG_STRICT            = 1 << 3
  JS_EVAL_FLAG_COMPILE_ONLY      = 1 << 5
  JS_EVAL_FLAG_BACKTRACE_BARRIER = 1 << 6
  JS_EVAL_FLAG_ASYNC             = 1 << 7

  # -- Runtime management --
  attach_function :js_newruntime, :JS_NewRuntime, [], :pointer
  attach_function :js_freeruntime, :JS_FreeRuntime, [:pointer], :void
  attach_function :js_setruntimeinfo, :JS_SetRuntimeInfo, [:pointer, :string], :void
  attach_function :js_setmemorylimit, :JS_SetMemoryLimit, [:pointer, :size_t], :void
  attach_function :js_setgcthreshold, :JS_SetGCThreshold, [:pointer, :size_t], :void
  attach_function :js_setmaxstacksize, :JS_SetMaxStackSize, [:pointer, :size_t], :void
  attach_function :js_rungc, :JS_RunGC, [:pointer], :void

  # -- Context management --
  attach_function :js_newcontext, :JS_NewContext, [:pointer], :pointer
  attach_function :js_freecontext, :JS_FreeContext, [:pointer], :void
  attach_function :js_getglobalobject, :JS_GetGlobalObject, [:pointer], JSValue.by_value

  # -- Value creation --
  attach_function :js_newnumber, :JS_NewNumber, [:pointer, :double], JSValue.by_value
  attach_function :js_newbigint64, :JS_NewBigInt64, [:pointer, :int64], JSValue.by_value
  attach_function :js_newstringlen, :JS_NewStringLen, [:pointer, :pointer, :size_t], JSValue.by_value
  attach_function :js_newarray, :JS_NewArray, [:pointer], JSValue.by_value
  attach_function :js_newobject, :JS_NewObject, [:pointer], JSValue.by_value

  # -- Value conversion --
  attach_function :js_tostring, :JS_ToString, [:pointer, JSValue.by_value], JSValue.by_value
  attach_function :js_tocstringlen2, :JS_ToCStringLen2, [:pointer, :pointer, JSValue.by_value, :bool], :pointer
  attach_function :js_freecstring, :JS_FreeCString, [:pointer, :pointer], :void
  attach_function :js_toint32, :JS_ToInt32, [:pointer, :pointer, JSValue.by_value], :int32
  attach_function :js_toint64, :JS_ToInt64, [:pointer, :pointer, JSValue.by_value], :int32
  attach_function :js_tofloat64, :JS_ToFloat64, [:pointer, :pointer, JSValue.by_value], :int32
  attach_function :js_tobool, :JS_ToBool, [:pointer, JSValue.by_value], :int32

  # -- Memory management --
  attach_function :js_freevalue, :JS_FreeValue, [:pointer, JSValue.by_value], :void
  attach_function :js_dupvalue, :JS_DupValue, [:pointer, JSValue.by_value], JSValue.by_value

  # -- Property access --
  attach_function :js_getpropertystr, :JS_GetPropertyStr, [:pointer, JSValue.by_value, :string], JSValue.by_value
  attach_function :js_getpropertyuint32, :JS_GetPropertyUint32, [:pointer, JSValue.by_value, :uint32], JSValue.by_value
  attach_function :js_setpropertystr, :JS_SetPropertyStr, [:pointer, JSValue.by_value, :string, JSValue.by_value], :int32
  attach_function :js_setpropertyuint32, :JS_SetPropertyUint32, [:pointer, JSValue.by_value, :uint32, JSValue.by_value], :int32
  attach_function :js_hasproperty, :JS_HasProperty, [:pointer, JSValue.by_value, :uint32], :int32

  # -- Atom handling --
  attach_function :js_newatom, :JS_NewAtom, [:pointer, :string], :uint32
  attach_function :js_freeatom, :JS_FreeAtom, [:pointer, :uint32], :void

  # -- Function calls --
  attach_function :js_call, :JS_Call, [:pointer, JSValue.by_value, JSValue.by_value, :int32, :pointer], JSValue.by_value
  attach_function :js_isfunction, :JS_IsFunction, [:pointer, JSValue.by_value], :bool

  # -- Type checking --
  attach_function :js_isarray, :JS_IsArray, [JSValue.by_value], :bool
  attach_function :js_ispromise, :JS_IsPromise, [JSValue.by_value], :bool
  attach_function :js_gettypedarraytype, :JS_GetTypedArrayType, [JSValue.by_value], :int32

  # -- Error handling --
  attach_function :js_getexception, :JS_GetException, [:pointer], JSValue.by_value
  attach_function :js_iserror, :JS_IsError, [JSValue.by_value], :bool

  # -- Code evaluation --
  attach_function :js_eval, :JS_Eval, [:pointer, :pointer, :size_t, :pointer, :int32], JSValue.by_value
  attach_function :js_detectmodule, :JS_DetectModule, [:pointer, :size_t], :bool

  # -- Job queue --
  attach_function :js_executependingjob, :JS_ExecutePendingJob, [:pointer, :pointer], :int32
  attach_function :js_isjobpending, :JS_IsJobPending, [:pointer], :bool

  # -- JSON --
  attach_function :js_jsonstringify, :JS_JSONStringify, [:pointer, JSValue.by_value, JSValue.by_value, JSValue.by_value], JSValue.by_value
end

# Helper module for JSValue construction and manipulation.
# Mirrors the `QuickJS` helper module from the Crystal source.
module QuickJS
  extend T::Sig

  # JSValue constructors
  sig { params(tag: Integer, val: Integer).returns(QuickJSBindings::JSValue) }
  def self.mkval(tag, val)
    v = QuickJSBindings::JSValue.new
    v[:u_int32] = val
    v[:u_float64_low] = 0
    v[:tag] = tag.to_i
    v
  end

  sig { params(tag: Integer, ptr: T.untyped).returns(QuickJSBindings::JSValue) }
  def self.mkptr(tag, ptr)
    addr = ptr.respond_to?(:address) ? ptr.address : ptr.to_i
    v = QuickJSBindings::JSValue.new
    v[:u_int32] = (addr & 0xFFFFFFFF)
    v[:u_float64_low] = ((addr >> 32) & 0xFFFFFFFF)
    v[:tag] = tag.to_i
    v
  end

  sig { params(val: Float).returns(QuickJSBindings::JSValue) }
  def self.mkfloat(val)
    bits = [val].pack("D").unpack1("Q")
    v = QuickJSBindings::JSValue.new
    v[:u_int32] = (bits & 0xFFFFFFFF)
    v[:u_float64_low] = ((bits >> 32) & 0xFFFFFFFF)
    v[:tag] = QuickJSBindings::JS_TAG_FLOAT64
    v
  end

  # JSValue accessors
  sig { params(v: QuickJSBindings::JSValue).returns(Integer) }
  def self.get_tag(v)
    v[:tag].to_i
  end

  sig { params(v: QuickJSBindings::JSValue).returns(Integer) }
  def self.get_int(v)
    v[:u_int32].to_i
  end

  sig { params(v: QuickJSBindings::JSValue).returns(T::Boolean) }
  def self.get_bool(v)
    v[:u_int32] != 0
  end

  sig { params(v: QuickJSBindings::JSValue).returns(Float) }
  def self.get_float(v)
    bits = ((v[:u_float64_low].to_i & 0xFFFFFFFF) << 32) | (v[:u_int32].to_i & 0xFFFFFFFF)
    [bits].pack("Q").unpack1("D")
  end

  sig { params(v: QuickJSBindings::JSValue).returns(FFI::Pointer) }
  def self.get_ptr(v)
    addr = ((v[:u_float64_low].to_i & 0xFFFFFFFF) << 32) | (v[:u_int32].to_i & 0xFFFFFFFF)
    FFI::Pointer.new(addr)
  end

  # Constant JSValue instances
  NULL          = T.let(mkval(QuickJSBindings::JS_TAG_NULL, 0), QuickJSBindings::JSValue)
  UNDEFINED     = T.let(mkval(QuickJSBindings::JS_TAG_UNDEFINED, 0), QuickJSBindings::JSValue)
  FALSE         = T.let(mkval(QuickJSBindings::JS_TAG_BOOL, 0), QuickJSBindings::JSValue)
  TRUE          = T.let(mkval(QuickJSBindings::JS_TAG_BOOL, 1), QuickJSBindings::JSValue)
  EXCEPTION     = T.let(mkval(QuickJSBindings::JS_TAG_EXCEPTION, 0), QuickJSBindings::JSValue)
  UNINITIALIZED = T.let(mkval(QuickJSBindings::JS_TAG_UNINITIALIZED, 0), QuickJSBindings::JSValue)

  # Type checking helpers
  sig { params(v: QuickJSBindings::JSValue).returns(T::Boolean) }
  def self.is_exception?(v)
    get_tag(v) == QuickJSBindings::JS_TAG_EXCEPTION
  end

  sig { params(v: QuickJSBindings::JSValue).returns(T::Boolean) }
  def self.is_undefined?(v)
    get_tag(v) == QuickJSBindings::JS_TAG_UNDEFINED
  end

  sig { params(v: QuickJSBindings::JSValue).returns(T::Boolean) }
  def self.is_null?(v)
    get_tag(v) == QuickJSBindings::JS_TAG_NULL
  end

  sig { params(v: QuickJSBindings::JSValue).returns(T::Boolean) }
  def self.is_bool?(v)
    get_tag(v) == QuickJSBindings::JS_TAG_BOOL
  end

  sig { params(v: QuickJSBindings::JSValue).returns(T::Boolean) }
  def self.is_int?(v)
    get_tag(v) == QuickJSBindings::JS_TAG_INT
  end

  sig { params(v: QuickJSBindings::JSValue).returns(T::Boolean) }
  def self.is_float?(v)
    get_tag(v) == QuickJSBindings::JS_TAG_FLOAT64
  end

  sig { params(v: QuickJSBindings::JSValue).returns(T::Boolean) }
  def self.is_number?(v)
    is_int?(v) || is_float?(v)
  end

  sig { params(v: QuickJSBindings::JSValue).returns(T::Boolean) }
  def self.is_object?(v)
    get_tag(v) == QuickJSBindings::JS_TAG_OBJECT
  end

  sig { params(v: QuickJSBindings::JSValue).returns(T::Boolean) }
  def self.is_string?(v)
    get_tag(v) == QuickJSBindings::JS_TAG_STRING
  end

  sig { params(v: QuickJSBindings::JSValue).returns(T::Boolean) }
  def self.is_symbol?(v)
    get_tag(v) == QuickJSBindings::JS_TAG_SYMBOL
  end
end
