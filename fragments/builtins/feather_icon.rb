# typed: true
class FeatherIcon

  @tag_name = "feather-icon"
  @icon

  attr_accessor :icon

  def initialize
    @icon = ""
  end

  def html
    %Q{
      <div class="feather-icon">
        {Mochi.raw(MochiIcons.icon(@icon))}
      </div>
    }
  end

  def css
    %Q{
      .feather-icon {
        display: inline-flex;
      }
    }
  end
end
