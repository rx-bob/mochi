# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

class EventArgumentExtractor
  extend T::Sig

  REGEX = T.let(
    /(on[a-z]+)\s*=\s*(["'])?\{([a-zA-Z0-9_\-\:]+)\s*\((.*?)\)\}\2?/m,
    Regexp
  )

  sig { params(html: String).returns(String) }
  def self.process(html)
    html.gsub(REGEX) do |_match|
      event_name = $1.to_s
      method_name = $3.to_s
      args_string = $4.to_s

      if args_string.strip.empty?
        "#{event_name}=\"{#{method_name}}\""
      else
        args = args_string.split(",").map(&:strip).reject(&:empty?)

        replacement = "#{event_name}=\"{#{method_name}}\""

        args.each_with_index do |arg, index|
          if arg == "$event" || arg == "$element"
            replacement += " data-mochi-arg-#{index}=\"#{arg}\""
          else
            replacement += " data-mochi-arg-#{index}=\"{#{arg}}\""
          end
        end

        replacement
      end
    end
  end
end
