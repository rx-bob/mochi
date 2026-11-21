require "../html/template_expression"

# Compiler-only tree shared by the DOM descriptor and the native scene.
# Browser comments and whitespace occupy DOM positions. Native output
# omits them, and uses component-local IDs plus a separate keyed row scope.
module PortableTemplate
  record SourceMark, kind : String, span : TemplateSourceSpan
  record BindingOperand, id : Int32
  record RowOperand, slot : Int32
  alias Part = String | BindingOperand | RowOperand
  alias Parts = Array(Part)
  record Action, method : String, event_args : Int32, row_context : Bool, supported : Bool = true

  abstract class Node
    property span : TemplateSourceSpan?
    property id : Int32 = 0
  end

  class Comment < Node
  end

  class Text < Node
    getter parts : Parts

    def initialize(@parts)
    end

    def visible? : Bool
      @parts.any? { |part| !part.is_a?(String) || !part.strip.empty? }
    end
  end

  class Element < Node
    getter tag : String
    getter attributes : Hash(String, Parts)
    getter children : Array(Node)
    getter action : Action?
    getter child_events : Hash(String, Action)

    def initialize(@tag, @attributes, @children, @action = nil, @child_events = {} of String => Action)
    end
  end

  # These nodes exist during the component/branch pass. Row fragment slots
  # belong to the invoking Rows node and never become component getter IDs.
  class Conditional < Node
    getter binding : Int32
    getter branches : Array(Array(Node))

    def initialize(@binding, @branches)
    end
  end

  class Rows < Node
    getter binding : Int32
    getter children : Array(Node)
    getter explicit_key : Bool
    getter flat : Bool

    def initialize(@binding, @children, @explicit_key, @flat)
    end
  end

  # Bindings and events attach to the visited node, including row events
  # registered at their list anchor. Paths are projected from DOM positions.
  class Fragment
    getter nodes : Array(Node)
    @bindings = {} of Node => Array(BindingDescriptor)
    @events = {} of Node => Array(EventDescriptor)

    def initialize(@nodes)
    end

    def attach(node : Node, bindings : Array(BindingDescriptor), events : Array(EventDescriptor)) : Nil
      @bindings[node] = bindings unless bindings.empty?
      @events[node] = events unless events.empty?
    end

    def project(bindings : Array(BindingDescriptor), events : Array(EventDescriptor)) : Nil
      bindings.clear
      events.clear
      project(@nodes, [] of Int32, bindings, events)
    end

    private def project(nodes : Array(Node), prefix : Array(Int32), bindings : Array(BindingDescriptor), events : Array(EventDescriptor)) : Nil
      nodes.each_with_index do |node, index|
        path = prefix + [index]
        if local = @bindings[node]?
          local.each do |binding|
            binding.path = path
            bindings << binding
          end
        end
        if local = @events[node]?
          local.each do |event|
            event.path = path
            events << event
          end
        end
        project(node.children, path, bindings, events) if node.is_a?(Element)
      end
    end
  end

  # The profile reads the raw Ruby literal. Match those authored spans to the
  # surviving typed nodes in preorder, including every conditional branch.
  class SourceMap
    @position = 0

    def initialize(@marks : Array(SourceMark), @component : String, @file : String?, @line : Int32)
    end

    def apply(nodes : Array(Node)) : Nil
      annotate(nodes)
      if mark = @marks[@position]?
        reject(mark.span, "template node was lost during compilation")
      end
    end

    private def annotate(nodes : Array(Node), text_leaf : Bool = false, in_row : Bool = false) : Nil
      nodes.each do |node|
        case node
        when Text
          locate(node, "text") if node.visible?
        when Element
          locate(node, node.tag)
          if action = node.action
            reject(node.span, "buttons accept one handler with an optional $event argument") unless action.supported
          end
          if !node.tag.in?("div", "span", "button")
            reject(node.span, "child components inside keyed rows require the portable keyed child lifecycle") if in_row
            if node.children.any? { |child| !child.is_a?(Comment) && !(child.is_a?(Text) && !child.visible?) }
              reject(node.span, "portable child components do not accept slotted content")
            end
          end
          node.child_events.each_value do |event|
            reject(node.span, "child connections accept one handler with an optional $event argument") unless event.supported
          end
          annotate(node.children, node.tag.in?("span", "button"), in_row)
        when Conditional
          locate(node, "cond")
          reject_leaf(node, text_leaf)
          node.branches.each { |branch| annotate(branch, in_row: in_row) }
        when Rows
          locate(node, "each")
          reject_leaf(node, text_leaf)
          unless node.explicit_key && node.flat
            reject(node.span, "lists require an explicit key and a flat row template")
          end
          annotate(node.children, in_row: true)
        end
      end
    end

    private def locate(node : Node, kind : String) : Nil
      mark = @marks[@position]?
      unless mark && mark.kind == kind
        reject(mark.try(&.span), "could not match compiled #{kind} to the authored template")
      end
      @position += 1
      node.id = @position
      node.span = mark.span
    end

    private def reject_leaf(node : Node, text_leaf : Bool) : Nil
      if text_leaf
        reject(node.span, "text leaves support scalar bindings; place conditionals and lists around the leaf")
      end
    end

    private def reject(span, message) : NoReturn
      raise "#{span || "#{@file}:#{@line}"}: portable component '#{@component}': #{message}"
    end
  end

  def self.parts(text : String, ranges : Array(Tuple(Int32, Int32, Part))) : Parts
    result = Parts.new
    offset = 0
    ranges.each do |start, finish, operand|
      result << literal(text.byte_slice(offset, start - offset)) if start > offset
      result << operand
      offset = finish
    end
    result << literal(text.byte_slice(offset, text.bytesize - offset)) if offset < text.bytesize
    result
  end

  private def self.literal(value : String) : String
    value.gsub('\uE000', '{').gsub('\uE001', '}')
  end
end
