require "set"

require "../../tree-sitter/ruby_parser"
require "../diagnostic"
require "../project_index"

module Lint::Rules
  # Opt-in row identity advice. The rule reports only two source-visible
  # patterns: an explicit key that resolves to a loop index, and a direct
  # sort/reverse/filter operation on literal rows that provably lack key/id
  # fields. Unknown collections and computed row shapes stay safe.
  module RowIdentity
    RULE = "templates/unstable-key"

    REORDERING_METHODS = Set{
      "sort", "sort!", "sort_by", "sort_by!",
      "reverse", "reverse!", "shuffle", "shuffle!",
      "select", "select!", "filter", "filter!",
      "reject", "reject!",
    }

    IDENTITY_KEYS = Set{"key", "id"}

    LITERAL_VALUE_TYPES = Set{
      "array",
      "bare_string",
      "bare_symbol",
      "character",
      "chained_string",
      "delimited_symbol",
      "false",
      "float",
      "integer",
      "nil",
      "regex",
      "simple_symbol",
      "string",
      "string_array",
      "symbol_array",
      "true",
    }

    enum Identity
      Present
      Missing
      Unknown
    end

    enum Binding
      Item
      Index
    end

    def self.diagnostics(index : ProjectIndex) : Array(Diagnostic)
      return [] of Diagnostic unless index.config.enabled?(RULE)
      severity = index.config.severity_for(RULE)
      return [] of Diagnostic unless severity

      issues = [] of SourceIssue
      parser = TreeSitter::RubyParser.new
      begin
        index.target_templates.each do |view|
          view.rows.each do |row|
            if name = index_key_name(parser, row)
              issues << row_issue(
                view,
                row,
                "each row key uses loop index '#{name}'; positional identity can associate drafts, focus, or child state with another record after reorder",
              )
            elsif method = reordered_literal_method(parser, row)
              issues << row_issue(
                view,
                row,
                "each row expression '#{row.items_expression}' uses '#{method}' on literal rows without a key or id; positional identity can associate drafts, focus, or child state with another record after reorder",
              )
            end
          end
        end
      ensure
        parser.close
      end

      Diagnostics.sort(issues.map { |issue| issue.diagnostic(severity) })
    end

    private def self.row_issue(view : TemplateView, row : TemplateRow, message : String) : SourceIssue
      SourceIssue.new(
        view.unit_path,
        view.map,
        row.start_byte,
        row.content_start_byte,
        message,
        RULE,
        "Add an explicit key using a stable domain identity.",
      )
    end

    private def self.index_key_name(parser : TreeSitter::RubyParser, row : TemplateRow) : String?
      key = row.key_expression
      return nil unless key
      name = identifier_name(parser, key)
      return nil unless name
      index_binding?(row, name) ? name : nil
    end

    # A key such as `index` can resolve to an item field when an outer loop
    # item shadows the implicit index name. Resolve names through the lexical
    # row chain, nearest binding last.
    private def self.index_binding?(row : TemplateRow, name : String) : Bool
      bindings = {} of String => Binding
      chain = [] of TemplateRow
      current = row
      while current
        chain << current
        current = current.parent
      end
      chain.reverse.each do |entry|
        bindings[entry.item_name] = Binding::Item
        bindings[entry.index_name] = Binding::Index unless entry.index_name == entry.item_name
        if entry.index_name != "index" && entry.item_name != "index"
          bindings["index"] = Binding::Index
        end
      end
      bindings[name]? == Binding::Index
    end

    private def self.reordered_literal_method(parser : TreeSitter::RubyParser, row : TemplateRow) : String?
      tree = parser.parse(row.items_expression)
      begin
        root = tree.root_node
        return nil if root.has_error?
        return nil unless root.named_child_count == 1
        current = unwrap(root.named_child(0))
        methods = [] of String

        while current.type == "call"
          method = current.child_by_field_name("method")
          receiver = current.child_by_field_name("receiver")
          return nil unless method && receiver
          methods << method.text
          current = unwrap(receiver)
        end

        method = methods.last?
        return nil unless method
        return nil unless REORDERING_METHODS.includes?(method)
        return nil unless literal_rows_without_identity?(current)
        method
      ensure
        tree.close
      end
    end

    private def self.literal_rows_without_identity?(node : TreeSitter::Node) : Bool
      case node.type
      when "string_array", "symbol_array"
        node.named_child_count > 0
      when "array"
        elements = [] of TreeSitter::Node
        node.each_named_child { |child| elements << child }
        return false if elements.empty?

        missing = false
        elements.each do |element|
          case row_identity(element)
          when Identity::Unknown
            return false
          when Identity::Missing
            missing = true
          end
        end
        missing
      else
        false
      end
    end

    private def self.row_identity(node : TreeSitter::Node) : Identity
      node = unwrap(node)
      case node.type
      when "hash"
        hash_identity(node)
      when "call", "constant", "element_reference", "identifier", "instance_variable",
           "scope_resolution", "self", "super"
        Identity::Unknown
      else
        LITERAL_VALUE_TYPES.includes?(node.type) ? Identity::Missing : Identity::Unknown
      end
    end

    private def self.hash_identity(node : TreeSitter::Node) : Identity
      unknown_key = false
      node.each_named_child do |child|
        case child.type
        when "hash_splat_argument"
          return Identity::Unknown
        when "pair"
          key = child.child_by_field_name("key")
          name = key_name(key)
          if name
            return Identity::Present if IDENTITY_KEYS.includes?(name)
          else
            unknown_key = true
          end
        end
      end
      unknown_key ? Identity::Unknown : Identity::Missing
    end

    private def self.key_name(node : TreeSitter::Node?) : String?
      return nil unless node
      case node.type
      when "hash_key_symbol", "bare_symbol"
        node.text
      when "simple_symbol"
        node.text.lchop(':')
      when "string", "delimited_symbol"
        content = node.named_child(0)
        if content && content.type == "string_content"
          content.text
        end
      else
        nil
      end
    end

    private def self.identifier_name(parser : TreeSitter::RubyParser, source : String) : String?
      tree = parser.parse(source)
      begin
        root = tree.root_node
        return nil if root.has_error?
        return nil unless root.named_child_count == 1
        node = unwrap(root.named_child(0))
        node.type == "identifier" ? node.text : nil
      ensure
        tree.close
      end
    end

    private def self.unwrap(node : TreeSitter::Node) : TreeSitter::Node
      while node.type == "parenthesized_statements" && node.named_child_count == 1
        node = node.named_child(0)
      end
      node
    end
  end
end
