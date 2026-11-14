class UnshiftChild
  @tag_name = "unshift-child"
  prop :items, Array, required: true

  def prepend
    @items.unshift(8)
  end

  def html
    %Q{
      <section>
        <button class="child-prepend" onclick="{prepend}">Prepend child</button>
        <output class="child-values">{@items.join(",")}</output>
      </section>
    }
  end
end

class UnshiftRoot
  @tag_name = "unshift-root"

  def initialize
    @values = [3]
    @values.unshift(1, 2)
    @alias = @values
  end

  def prepend_and_replace
    @values.unshift(4, 5)
    @values = [0] + @values
  end

  def html
    %Q{
      <main>
        <button class="root-prepend" onclick="{prepend_and_replace}">Prepend and replace</button>
        <output class="root-values">{@values.join(",")}</output>
        <output class="alias-values">{@alias.join(",")}</output>
        <unshift-child items="{@values}"></unshift-child>
      </main>
    }
  end
end
