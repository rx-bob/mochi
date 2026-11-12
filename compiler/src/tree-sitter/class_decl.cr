require "./ruby_parser"

module TreeSitter
  # One `class` or `module` declaration in a Ruby source file.
  #
  # A class may be reopened, so one logical class can have several ClassDecl
  # entries. Byte ranges always refer to the original source; callers must not
  # use them against a rewritten slice.
  class ClassDecl
    getter node : Node
    getter name : String
    getter simple_name : String
    getter qualified_name : String
    getter kind : String
    getter start_byte : Int32
    getter end_byte : Int32
    getter line : Int32
    getter enclosing : Array(String)
    getter wrapper_start_byte : Int32
    getter wrapper_end_byte : Int32
    getter tag_name : String?
    getter method_names : Array(String)
    getter attribute_readers : Set(String)
    getter has_html : Bool
    getter has_css : Bool

    def initialize(
      @node : Node,
      @name : String,
      @kind : String,
      @start_byte : Int32,
      @end_byte : Int32,
      @line : Int32,
      @enclosing : Array(String),
      @wrapper_start_byte : Int32,
      @wrapper_end_byte : Int32,
      @tag_name : String?,
      @method_names : Array(String),
      @attribute_readers : Set(String),
    )
      @simple_name = @name.split("::").last
      @qualified_name = (@enclosing + [@name]).reject(&.empty?).join("::")
      @has_html = @method_names.includes?("html")
      @has_css = @method_names.includes?("css")
    end

    def class? : Bool
      @kind == "class"
    end

    def component? : Bool
      !@tag_name.nil?
    end

    def range : Tuple(Int32, Int32)
      {@start_byte, @end_byte}
    end

    def location(file : String) : String
      "#{file}:#{@line}"
    end
  end
end
