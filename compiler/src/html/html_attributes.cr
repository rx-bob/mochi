# HTML attributes need different DOM semantics than plain text values.
#
# Boolean attributes are present or absent: an empty or `false` Ruby value
# removes them. Textual attributes (`aria-*`, `data-*`, `class`, `title`, and
# the rest) keep the authored string even when it is `"false"`, `"0"`, or
# empty. Live form properties such as `value` and `checked` are compiled as
# property bindings and never use this classification.
class HtmlAttributes
  BOOLEAN_ATTRIBUTES = [
    "allowfullscreen",
    "async",
    "autofocus",
    "autoplay",
    "checked",
    "controls",
    "default",
    "defer",
    "disabled",
    "formnovalidate",
    "hidden",
    "inert",
    "ismap",
    "itemscope",
    "loop",
    "multiple",
    "muted",
    "nomodule",
    "novalidate",
    "open",
    "playsinline",
    "readonly",
    "required",
    "reversed",
    "selected",
  ]

  TEXTUAL_PREFIXES = ["aria-", "data-"]

  def self.kind(name : String) : String
    normalized = name.downcase
    return "text" if TEXTUAL_PREFIXES.any? { |prefix| normalized.starts_with?(prefix) }
    BOOLEAN_ATTRIBUTES.includes?(normalized) ? "boolean" : "text"
  end
end
