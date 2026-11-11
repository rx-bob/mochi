class RubyDef
  property name : String?
  property file_name : String
  property class_name : String
  property body : Array(String)
  property parameters : Array(String)
  property raw_string : String?

  def initialize(@name, @file_name, @class_name, @body, @parameters, @raw_string : String? = nil)
  end
end
