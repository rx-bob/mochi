class ConfirmDialog
  @tag_name = "confirm-dialog"
  prop :title, String, required: true
  prop :message, String, required: true
  prop :confirm_label, String, default: "Confirm"
  prop :cancel_label, String, default: "Cancel"
  event :confirm, accepted: Boolean
  event :cancel, reason: String

  def mounted
    MochiShortcuts.register("Escape", "shortcut_cancel",
      {"scope" => "application", "active_ref" => "dialog", "prevent" => true, "allow_editable" => true})
    Mochi.focus("cancel")
  end

  def confirm
    emit("confirm", {"accepted" => true})
  end

  def cancel
    emit("cancel", {"reason" => "button"})
  end

  def shortcut_cancel(result)
    emit("cancel", {"reason" => "escape"}) if result["ok"]
  end

  def html
    %Q{
      <section ref="dialog" class="dialog" role="dialog" aria-modal="true" aria-labelledby="dialog-title" tabindex="-1">
        <h2 id="dialog-title" class="title">{@title}</h2>
        <p class="message">{@message}</p>
        <div class="actions">
          <button ref="cancel" class="cancel" type="button" tabindex="0" onclick="{cancel}">{@cancel_label}</button>
          <button ref="confirm" class="confirm" type="button" tabindex="0" onclick="{confirm}">{@confirm_label}</button>
        </div>
      </section>
    }
  end
end
