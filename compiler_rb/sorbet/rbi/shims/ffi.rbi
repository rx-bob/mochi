# typed: true
# frozen_string_literal: true

# RBI shim for the ffi gem so Sorbet understands FFI::Library, FFI::Pointer, etc.
module FFI
  class Pointer
    sig { returns(T::Boolean) }
    def null?; end

    sig { returns(T.nilable(Pointer)) }
    def self.NULL; end

    NULL = T.let(T.unsafe(nil), Pointer)

    sig { returns(Integer) }
    def address; end

    sig { params(offset: Integer).returns(Pointer) }
    def +(offset); end
  end

  class MemoryPointer < Pointer
    sig { params(type: Symbol, size: Integer).void }
    def initialize(type, size); end

    sig { returns(Integer) }
    def size; end

    sig { params(len: Integer).returns(String) }
    def read_string(len); end

    sig { returns(Integer) }
    def read_int; end

    sig { returns(Integer) }
    def read_uint64; end
  end

  module Library
    sig { params(name: T.any(String, Symbol)).void }
    def ffi_lib(name); end

    sig { params(name: Symbol, args: T::Array[Symbol], ret: Symbol).void }
    def attach_function(name, args, ret); end
  end

  class Struct
    sig { params(type: Symbol, size: Integer).returns(MemoryPointer) }
    def self.new(type, size); end
  end

  sig { returns(Pointer) }
  def self::NULL; end
end
