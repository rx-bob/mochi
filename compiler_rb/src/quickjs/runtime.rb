# typed: false
# frozen_string_literal: true

require "sorbet-runtime"
require_relative "bindings"
require_relative "value"
require_relative "error"

module QuickJS
  class Runtime
    extend T::Sig

    sig { returns(FFI::Pointer) }
    attr_reader :handle

    sig { returns(FFI::Pointer) }
    attr_reader :context

    sig { void }
    def initialize
      @handle = QuickJSBindings.js_newruntime
      @context = QuickJSBindings.js_newcontext(@handle)
      @released = false
    end

    sig { void }
    def close
      return if @released
      @released = true
      QuickJSBindings.js_freecontext(@context)
      QuickJSBindings.js_freeruntime(@handle)
    end

    alias_method :finalize, :close

    sig { params(code: String, filename: String).returns(Value) }
    def eval(code, filename = "eval.js")
      input = code.dup.force_encoding("UTF-8")
      fname = filename.dup.force_encoding("UTF-8")

      js_val = QuickJSBindings.js_eval(
        @context,
        input,
        input.bytesize,
        fname,
        QuickJSBindings::JS_EVAL_TYPE_GLOBAL
      )

      if QuickJS.is_exception?(js_val)
        check_exception!
        raise Error.new("Unknown error during evaluation")
      end

      val = Value.new(self, js_val)
      QuickJSBindings.js_freevalue(@context, js_val)
      val
    end

    sig { params(path: String).returns(Value) }
    def eval_file(path)
      code = File.read(path)
      eval(code, path)
    end

    sig { params(key: String).returns(Value) }
    def [](key)
      global = QuickJSBindings.js_getglobalobject(@context)
      prop = QuickJSBindings.js_getpropertystr(@context, global, key)
      QuickJSBindings.js_freevalue(@context, global)

      val = Value.new(self, prop)
      QuickJSBindings.js_freevalue(@context, prop)
      val
    end

    sig { params(key: String, value: T.untyped).void }
    def []=(key, value)
      global = QuickJSBindings.js_getglobalobject(@context)
      js_val = to_js_value(value)
      QuickJSBindings.js_setpropertystr(@context, global, key, js_val)
      QuickJSBindings.js_freevalue(@context, global)
    end

    sig { params(function_name: String, args: T.untyped).returns(Value) }
    def call(function_name, *args)
      global = QuickJSBindings.js_getglobalobject(@context)
      func_obj = QuickJSBindings.js_getpropertystr(@context, global, function_name)
      QuickJSBindings.js_freevalue(@context, global)

      unless QuickJSBindings.js_isfunction(@context, func_obj)
        QuickJSBindings.js_freevalue(@context, func_obj)
        raise TypeError.new("'#{function_name}' is not a function")
      end

      js_args = args.map { |arg| to_js_value(arg) }
      if js_args.empty?
        argv_ptr = nil
      else
        argv_ptr = FFI::MemoryPointer.new(QuickJSBindings::JSValue.size * js_args.size)
        js_args.each_with_index do |arg, i|
          argv_ptr.put_bytes(i * QuickJSBindings::JSValue.size, arg.pointer.get_bytes(0, QuickJSBindings::JSValue.size))
        end
      end

      result = QuickJSBindings.js_call(
        @context,
        func_obj,
        QuickJS::UNDEFINED,
        js_args.size,
        argv_ptr
      )
      QuickJSBindings.js_freevalue(@context, func_obj)

      if QuickJS.is_exception?(result)
        check_exception!
        raise Error.new("Error calling function '#{function_name}'")
      end

      val = Value.new(self, result)
      QuickJSBindings.js_freevalue(@context, result)
      val
    end

    sig { params(value: T.untyped).returns(QuickJSBindings::JSValue) }
    def to_js_value(value)
      case value
      when Integer
        if value.bit_length <= 32
          QuickJS.mkval(QuickJSBindings::JS_TAG_INT, value)
        else
          QuickJSBindings.js_newbigint64(@context, value)
        end
      when String
        QuickJSBindings.js_newstringlen(@context, value, value.bytesize)
      when Float
        QuickJSBindings.js_newnumber(@context, value)
      when TrueClass, FalseClass
        value ? QuickJS::TRUE : QuickJS::FALSE
      when NilClass
        QuickJS::NULL
      when Value
        QuickJSBindings.js_dupvalue(@context, value.handle)
      when Array
        arr = QuickJSBindings.js_newarray(@context)
        value.each_with_index do |v, i|
          js_v = to_js_value(v)
          QuickJSBindings.js_setpropertyuint32(@context, arr, i.to_i, js_v)
        end
        arr
      when Hash
        obj = QuickJSBindings.js_newobject(@context)
        value.each do |k, v|
          js_v = to_js_value(v)
          QuickJSBindings.js_setpropertystr(@context, obj, k.to_s, js_v)
        end
        obj
      else
        # Fallback for anything we don't know about
        QuickJSBindings.js_newstringlen(@context, value.to_s, value.to_s.bytesize)
      end
    end

    sig { void }
    def gc
      QuickJSBindings.js_rungc(@handle)
    end

    sig { params(limit: Integer).void }
    def set_memory_limit(limit)
      QuickJSBindings.js_setmemorylimit(@handle, limit)
    end

    sig { params(threshold: Integer).void }
    def set_gc_threshold(threshold)
      QuickJSBindings.js_setgcthreshold(@handle, threshold)
    end

    sig { params(stack_size: Integer).void }
    def set_max_stack_size(stack_size)
      QuickJSBindings.js_setmaxstacksize(@handle, stack_size)
    end

    sig { void }
    def run_jobs
      pctx_ptr = FFI::MemoryPointer.new(:pointer, 1)
      pctx_ptr.put_pointer(0, nil)
      loop do
        ret = QuickJSBindings.js_executependingjob(@handle, pctx_ptr)
        break if ret == 0
        break if ret < 0
      end
    end

    sig { params(code: String).returns(Value) }
    def eval_async(code)
      val = eval(code)
      run_jobs if val.promise?
      val
    end

    sig { params(path: String).returns(Value) }
    def load_module(path)
      code = File.read(path)

      js_val = QuickJSBindings.js_eval(
        @context,
        code,
        code.bytesize,
        path,
        QuickJSBindings::JS_EVAL_TYPE_MODULE
      )

      if QuickJS.is_exception?(js_val)
        check_exception!
        raise Error.new("Failed to compile module")
      end

      val = Value.new(self, js_val)
      QuickJSBindings.js_freevalue(@context, js_val)
      val
    end

    sig { void }
    def check_exception!
      exception_val = QuickJSBindings.js_getexception(@context)

      str_val = QuickJSBindings.js_tostring(@context, exception_val)
      plen_ptr = FFI::MemoryPointer.new(:size_t, 1)
      str_ptr = QuickJSBindings.js_tocstringlen2(@context, plen_ptr, str_val, false)
      message = str_ptr.get_bytes(0, plen_ptr.read_uint64)

      QuickJSBindings.js_freecstring(@context, str_ptr)
      QuickJSBindings.js_freevalue(@context, str_val)
      QuickJSBindings.js_freevalue(@context, exception_val)

      case message
      when /\ASyntaxError:/
        raise SyntaxError.new(message)
      when /\AReferenceError:/
        raise ReferenceError.new(message)
      when /\ATypeError:/
        raise TypeError.new(message)
      when /\ARangeError:/
        raise RangeError.new(message)
      when /\AInternalError:/
        raise InternalError.new(message)
      when /\AEvalError:/
        raise EvalError.new(message)
      else
        raise Error.new(message)
      end
    end
  end
end
