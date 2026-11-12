class RubyDef
  property name : String?
  property file_name : String
  property class_name : String
  property body : Array(String)
  property parameters : Array(String)
  property raw_string : String?
  property raw_string_start : Int32?
  property raw_string_end : Int32?
  property start_line : Int32

  def initialize(
    @name,
    @file_name,
    @class_name,
    @body,
    @parameters,
    @raw_string : String? = nil,
    @raw_string_start : Int32? = nil,
    @raw_string_end : Int32? = nil,
    @start_line : Int32 = 0,
  )
  end
end
