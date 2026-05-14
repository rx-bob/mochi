# typed: true
# frozen_string_literal: true

require_relative "bindings"

module TreeSitter
  class Node
    extend T::Sig

    sig { returns(T.untyped) }
    attr_reader :raw

    sig { returns(String) }
    attr_reader :source

    sig { params(raw: T.untyped, source: String).void }
    def initialize(raw, source)
      @raw = raw
      @source = source
    end

    sig { returns(String) }
    def type
      TreeSitterBindings.ts_node_type(@raw)
    end

    sig { returns(T::Boolean) }
    def null?
      TreeSitterBindings.ts_node_is_null(@raw)
    end

    sig { returns(Integer) }
    def child_count
      TreeSitterBindings.ts_node_child_count(@raw).to_i
    end

    sig { returns(Integer) }
    def named_child_count
      TreeSitterBindings.ts_node_named_child_count(@raw).to_i
    end

    sig { params(index: Integer).returns(Node) }
    def child(index)
      raw_child = TreeSitterBindings.ts_node_child(@raw, index)
      Node.new(raw_child, @source)
    end

    sig { params(index: Integer).returns(Node) }
    def named_child(index)
      raw_child = TreeSitterBindings.ts_node_named_child(@raw, index)
      Node.new(raw_child, @source)
    end

    sig { params(field_name: String).returns(T.nilable(Node)) }
    def child_by_field_name(field_name)
      raw_child = TreeSitterBindings.ts_node_child_by_field_name(
        @raw,
        field_name,
        field_name.bytesize
      )
      return nil if TreeSitterBindings.ts_node_is_null(raw_child)
      Node.new(raw_child, @source)
    end

    sig { returns(String) }
    def text
      start_byte = TreeSitterBindings.ts_node_start_byte(@raw)
      end_byte = TreeSitterBindings.ts_node_end_byte(@raw)
      T.must(@source.byteslice(start_byte, end_byte - start_byte))
    end

    sig { returns(String) }
    def to_s
      "#{type} [#{TreeSitterBindings.ts_node_start_byte(@raw)}-#{TreeSitterBindings.ts_node_end_byte(@raw)}]"
    end

    sig { params(block: T.proc.params(node: Node).void).void }
    def each_child(&block)
      child_count.times do |i|
        block.call(child(i))
      end
    end

    sig { params(block: T.proc.params(node: Node).void).void }
    def each_named_child(&block)
      named_child_count.times do |i|
        block.call(named_child(i))
      end
    end
  end

  class RubyParser
    extend T::Sig

    sig { void }
    def initialize
      @parser = T.let(TreeSitterBindings.ts_parser_new, T.untyped)
      language = TreeSitterBindings.tree_sitter_ruby
      success = TreeSitterBindings.ts_parser_set_language(@parser, language)
      raise "Failed to set Ruby language" unless success
    end

    sig { params(source: String).returns(Tree) }
    def parse(source)
      tree_ptr = TreeSitterBindings.ts_parser_parse_string(
        @parser,
        nil,
        source,
        source.bytesize
      )
      Tree.new(tree_ptr, source)
    end

    sig { void }
    def close
      TreeSitterBindings.ts_parser_delete(@parser)
    end
  end

  class Tree
    extend T::Sig

    sig { params(tree_ptr: T.untyped, source: String).void }
    def initialize(tree_ptr, source)
      @tree = tree_ptr
      @source = source
    end

    sig { returns(Node) }
    def root_node
      raw_node = TreeSitterBindings.ts_tree_root_node(@tree)
      Node.new(raw_node, @source)
    end

    sig { void }
    def close
      TreeSitterBindings.ts_tree_delete(@tree)
    end
  end
end
