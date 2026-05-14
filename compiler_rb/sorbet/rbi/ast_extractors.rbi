# typed: true
# frozen_string_literal: true

module TreeSitter
  class Node
    sig { returns(String) }
    def type; end

    sig { returns(T::Boolean) }
    def null?; end

    sig { returns(Integer) }
    def child_count; end

    sig { returns(Integer) }
    def named_child_count; end

    sig { params(index: Integer).returns(Node) }
    def child(index); end

    sig { params(index: Integer).returns(Node) }
    def named_child(index); end

    sig { params(field_name: String).returns(T.nilable(Node)) }
    def child_by_field_name(field_name); end

    sig { returns(String) }
    def text; end

    sig { returns(String) }
    def to_s; end

    sig { params(block: T.proc.params(node: Node).void).void }
    def each_child(&block); end

    sig { params(block: T.proc.params(node: Node).void).void }
    def each_named_child(&block); end
  end

  class Tree
    sig { returns(Node) }
    def root_node; end

    sig { void }
    def close; end
  end

  class RubyParser
    sig { void }
    def initialize; end

    sig { params(source: String).returns(Tree) }
    def parse(source); end

    sig { void }
    def close; end
  end

  class ClassExtractor
    sig { params(source: String).returns(T::Array[String]) }
    def self.extract_class_names(source); end

    sig { params(source: String).returns(String) }
    def self.class_name(source); end

    sig { params(source: String).returns(T.nilable(String)) }
    def self.extract_superclass(source); end
  end

  class PropertyExtractor
    sig { params(source: String, property_name: String).returns(T.nilable(String)) }
    def self.extract_property(source, property_name); end
  end

  class ImportsExtractor
    sig { params(source: String).returns(T::Array[String]) }
    def self.extract_imports(source); end
  end

  class MethodBodyExtractor
    sig { params(source: String, class_name: String).returns(T::Hash[String, RubyDef]) }
    def self.extract_method_bodies(source, class_name); end
  end

  class StringExtractor
    sig { params(body: T::Array[String], name: String).returns(String) }
    def self.extract_raw_string_from_def_body(body, name); end
  end
end

