# typed: true
class BooleanEditor
  @tag_name = "boolean-editor"
  prop :required, Boolean, required: true
  prop :enabled, Boolean, default: false
  event :save, valid: Boolean
  def good
    emit("save", {"valid" => false})
  end
  def bad
    emit("save", {"valid" => "false"})
  end
  def html
    %q{<output>{@required}:{@enabled}</output><button class="good" onclick="{good}">Good</button><button class="bad" onclick="{bad}">Bad</button>}
  end
end
