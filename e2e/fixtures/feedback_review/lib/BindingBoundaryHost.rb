class BindingBoundaryHost
  @tag_name = "binding-boundary-host"
  def initialize
    @first_seed = 10
    @second_seed = 20
    @rows = [{"id" => "a", "label" => "Alpha", "meta" => {"value" => "A"}}, {"id" => "b", "label" => "Beta", "meta" => {"value" => "B"}}]
  end
  def replace_inputs
    @first_seed = 30
    @second_seed = 70
    @rows = [{"id" => "b", "label" => "Beta2", "meta" => {"value" => "B2"}}, {"id" => "a", "label" => "Alpha2", "meta" => {"value" => "A2"}}]
  end
  def html
    %Q{
      <main>
        <button class="replace-boundary-inputs" onclick="{replace_inputs}">Replace inputs</button>
        <binding-boundary class="first" seed="{@first_seed}" rows="{@rows}"></binding-boundary>
        <binding-boundary class="second" seed="{@second_seed}" rows="{@rows}"></binding-boundary>
      </main>
    }
  end
end
