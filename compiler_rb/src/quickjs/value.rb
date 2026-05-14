# typed: false
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "bindings"
require_relative "error"

module QuickJS
  class Value
    extend T::Sig

    sig { returns(QuickJSBindings::JSValue) }
    attr_reader :handle

    sig { returns(Runtime) }
    attr_reader :runtime

    sig { params(runtime: Runtime, handle: QuickJSBindings::JSValue).void }
    def initialize(runtime, handle)
      @runtime = runtime
      @handle = QuickJSBindings.js_dupvalue(runtime.context, handle)
      @freed = false
    end

    sig { void }
    def close
      return if @freed
      @freed = true
      QuickJSBindings.js_freevalue(@runtime.context, @handle)
    end

    alias_method :finalize, :close

    sig { returns(T::Boolean) }
    def undefined?
      QuickJS.is_undefined?(@handle)
    end

    sig { returns(T::Boolean) }
    def null?
      QuickJS.is_null?(@handle)
    end

    sig { returns(T::Boolean) }
    def boolean?
      QuickJS.is_bool?(@handle)
    end

    sig { returns(T::Boolean) }
    def number?
      QuickJS.is_number?(@handle)
    end

    sig { returns(T::Boolean) }
    def string?
      QuickJS.is_string?(@handle)
    end

    sig { returns(T::Boolean) }
    def object?
      QuickJS.is_object?(@handle)
    end

    sig { returns(T::Boolean) }
    def array?
      QuickJSBindings.js_isarray(@handle)
    end

    sig { returns(T::Boolean) }
    def function?
      QuickJSBindings.js_isfunction(@runtime.context, @handle)
    end

    sig { returns(T::Boolean) }
    def exception?
      QuickJS.is_exception?(@handle)
    end

    sig { returns(Integer) }
    def to_i
      raise TypeError.new("Value is not a number") unless number?

      ptr = FFI::MemoryPointer.new(:int32, 1)
      ret = QuickJSBindings.js_toint32(@runtime.context, ptr, @handle)
      raise Error.new("Conversion to Int32 failed") if ret != 0
      ptr.read_int32
    end

    sig { returns(Integer) }
    def to_i64
      raise TypeError.new("Value is not a number") unless number?

      ptr = FFI::MemoryPointer.new(:int64, 1)
      ret = QuickJSBindings.js_toint64(@runtime.context, ptr, @handle)
      raise Error.new("Conversion to Int64 failed") if ret != 0
      ptr.read_int64
    end

    sig { returns(Float) }
    def to_f
      raise TypeError.new("Value is not a number") unless number?

      ptr = FFI::MemoryPointer.new(:double, 1)
      ret = QuickJSBindings.js_tofloat64(@runtime.context, ptr, @handle)
      raise Error.new("Conversion to Float64 failed") if ret != 0
      ptr.read_double
    end

    sig { returns(String) }
    def to_s
      str_val = QuickJSBindings.js_tostring(@runtime.context, @handle)

      if QuickJS.is_exception?(str_val)
        QuickJSBindings.js_freevalue(@runtime.context, str_val)
        raise Error.new("Could not convert value to string")
      end

      plen_ptr = FFI::MemoryPointer.new(:size_t, 1)
      str_ptr = QuickJSBindings.js_tocstringlen2(@runtime.context, plen_ptr, str_val, false)

      if str_ptr.null?
        QuickJSBindings.js_freevalue(@runtime.context, str_val)
        raise Error.new("Could not get C string from value")
      end

      plen = plen_ptr.read_uint64
      result = str_ptr.get_bytes(0, plen)

      QuickJSBindings.js_freecstring(@runtime.context, str_ptr)
      QuickJSBindings.js_freevalue(@runtime.context, str_val)

      result
    end

    sig { returns(T::Boolean) }
    def to_bool
      res = QuickJSBindings.js_tobool(@runtime.context, @handle)
      if res == -1
        raise Error.new("Could not convert value to boolean")
      end
      res != 0
    end

    sig { returns(T::Array[Value]) }
    def to_a
      raise TypeError.new("Value is not an array") unless array?

      result = []
      each { |val| result << val }
      result
    end

    sig { returns(T::Hash[String, Value]) }
    def to_h
      raise TypeError.new("Value is not an object") unless object?

      result = {}
      keys.each { |key| result[key] = self[key] }
      result
    end

    sig { returns(String) }
    def to_json
      str_val = QuickJSBindings.js_jsonstringify(
        @runtime.context,
        @handle,
        QuickJS::UNDEFINED,
        QuickJS::UNDEFINED
      )
      if QuickJS.is_exception?(str_val)
        QuickJSBindings.js_freevalue(@runtime.context, str_val)
        raise Error.new("Failed to stringify to JSON")
      end

      val = Value.new(@runtime, str_val)
      result = val.to_s
      val.close
      result
    end

    sig { returns(T::Boolean) }
    def promise?
      QuickJSBindings.js_ispromise(@handle)
    end

    sig { returns(T::Boolean) }
    def uint8_array?
      QuickJSBindings.js_gettypedarraytype(@handle) != 0
    end

    sig { params(key: T.any(String, Integer)).returns(Value) }
    def [](key)
      case key
      when String
        prop = QuickJSBindings.js_getpropertystr(@runtime.context, @handle, key)
      when Integer
        prop = QuickJSBindings.js_getpropertyuint32(@runtime.context, @handle, key.to_i)
      else
        raise TypeError.new("Key must be String or Integer, got #{key.class}")
      end
      Value.new(@runtime, prop)
    end

    sig { params(key: T.any(String, Integer), value: T.untyped).void }
    def []=(key, value)
      js_val = @runtime.to_js_value(value)
      case key
      when String
        QuickJSBindings.js_setpropertystr(@runtime.context, @handle, key, js_val)
      when Integer
        QuickJSBindings.js_setpropertyuint32(@runtime.context, @handle, key.to_i, js_val)
      else
        raise TypeError.new("Key must be String or Integer, got #{key.class}")
      end
    end

    sig { params(key: T.any(String, Integer)).returns(T::Boolean) }
    def has_key?(key)
      atom = QuickJSBindings.js_newatom(@runtime.context, key.to_s)
      ret = QuickJSBindings.js_hasproperty(@runtime.context, @handle, atom)
      QuickJSBindings.js_freeatom(@runtime.context, atom)
      ret != 0
    end

    sig { returns(T::Array[String]) }
    def keys
      global = QuickJSBindings.js_getglobalobject(@runtime.context)
      object_cls = QuickJSBindings.js_getpropertystr(@runtime.context, global, "Object")
      keys_func = QuickJSBindings.js_getpropertystr(@runtime.context, object_cls, "keys")

      argv_ptr = FFI::MemoryPointer.new(QuickJSBindings::JSValue.size)
      argv_ptr.put_bytes(0, @handle.pointer.get_bytes(0, QuickJSBindings::JSValue.size))
      result = QuickJSBindings.js_call(
        @runtime.context,
        keys_func,
        QuickJS::UNDEFINED,
        1,
        argv_ptr
      )

      QuickJSBindings.js_freevalue(@runtime.context, keys_func)
      QuickJSBindings.js_freevalue(@runtime.context, object_cls)
      QuickJSBindings.js_freevalue(@runtime.context, global)

      if QuickJS.is_exception?(result)
        QuickJSBindings.js_freevalue(@runtime.context, result)
        raise Error.new("Failed to get keys")
      end

      keys_val = Value.new(@runtime, result)
      arr = []
      keys_val.each { |k| arr << k.to_s }
      keys_val.close
      arr
    end

    sig { params(args: T.untyped).returns(Value) }
    def call(*args)
      call_with_this(nil, *args)
    end

    sig { params(block: T.proc.params(val: Value).returns(T.untyped)).returns(T::Array[T.untyped]) }
    def map(&block)
      result = []
      each { |val| result << block.call(val) }
      result
    end

    sig { params(this_obj: T.nilable(Value), args: T.untyped).returns(Value) }
    def call_with_this(this_obj = nil, *args)
      raise TypeError.new("Value is not a function") unless function?

      js_this = if this_obj
                   this_obj.handle
                 else
                   QuickJS::UNDEFINED
                 end

      js_args = args.map { |arg| @runtime.to_js_value(arg) }
      if js_args.empty?
        argv_ptr = nil
      else
        argv_ptr = FFI::MemoryPointer.new(QuickJSBindings::JSValue.size * js_args.size)
        js_args.each_with_index do |arg, i|
          argv_ptr.put_bytes(i * QuickJSBindings::JSValue.size, arg.pointer.get_bytes(0, QuickJSBindings::JSValue.size))
        end
      end

      result = QuickJSBindings.js_call(
        @runtime.context,
        @handle,
        js_this,
        js_args.size,
        argv_ptr
      )

      if QuickJS.is_exception?(result)
        @runtime.check_exception!
        raise Error.new("Function call failed")
      end

      Value.new(@runtime, result)
    end

    sig { returns(Integer) }
    def size
      len_val = QuickJSBindings.js_getpropertystr(@runtime.context, @handle, "length")
      val = Value.new(@runtime, len_val)
      val.to_i
    ensure
      val.close if defined?(val) && val
    end

    sig { params(block: T.proc.params(val: Value).void).void }
    def each(&block)
      sz = size
      sz.times do |i|
        block.call(self[i])
      end
    end

    sig { params(default: Integer).returns(Integer) }
    def as_i(default = 0)
      to_i
    rescue
      default
    end

    sig { params(default: Float).returns(Float) }
    def as_f(default = 0.0)
      to_f
    rescue
      default
    end

    sig { params(default: String).returns(String) }
    def as_s(default = "")
      to_s
    rescue
      default
    end

    sig { params(default: T::Boolean).returns(T::Boolean) }
    def as_bool(default = false)
      to_bool
    rescue
      default
    end
  end
end
