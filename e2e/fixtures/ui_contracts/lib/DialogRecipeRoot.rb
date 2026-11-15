class DialogRecipeRoot
  @tag_name = "dialog-recipe-root"
  @open
  @trigger_visible
  @title
  @message
  @result

  def initialize
    @open = false
    @trigger_visible = true
    @title = "Delete draft?"
    @message = "This action removes the current draft."
    @result = "none"
  end

  def open_dialog
    @open = true
    Mochi.focus("dialog")
  end

  def confirm_dialog(payload)
    @result = "confirmed:#{payload["accepted"]}"
    close_dialog
  end

  def cancel_dialog(payload)
    @result = "cancelled:#{payload["reason"]}"
    close_dialog
  end

  def close_dialog
    @open = false
    if @trigger_visible
      Mochi.restore_focus
    else
      Mochi.focus("fallback")
    end
  end

  def update_dialog_data
    @title = %q(Delete "Draft" <img data-injected="yes">?)
    @message = %q(User text: <strong>keep this literal</strong> & continue)
  end

  def remove_trigger
    @trigger_visible = false
  end

  def html
    %Q{
      <h1>Dialog recipe</h1>
      {if @trigger_visible}<button ref="opener" class="open" type="button" onclick="{open_dialog}">Open dialog</button>{else}<p class="opener-removed">Opener removed</p>{end}
      <button class="remove-trigger" type="button" onclick="{remove_trigger}">Remove opener</button>
      <button ref="fallback" class="fallback" type="button">Fallback focus</button>
      <button class="update-data" type="button" onclick="{update_dialog_data}">Update dialog text</button>
      <output class="result">{@result}</output>
      {if @open}
        <confirm-dialog ref="dialog" tabindex="-1" data-mochi-focus-trap title="{@title}" message="{@message}" on:confirm="{confirm_dialog($event)}" on:cancel="{cancel_dialog($event)}"></confirm-dialog>
      {end}
    }
  end
end
