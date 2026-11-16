require "set"

require "../html/template_expression"
require "./diagnostic"
require "./project_index"
require "./rule_registry"
require "./template_elements"

module Lint::Suppressions
  PREFIX = "mochi-lint:"

  UNSUPPRESSIBLE_RULES = Set{
    Lint::SYNTAX_RULE,
    Lint::ANALYSIS_RULE,
    Lint::SUPPRESSION_RULE,
  }

  RUBY_CONSTRUCT_TYPES = Set{
    "alias",
    "array",
    "assignment",
    "begin",
    "binary",
    "block",
    "break",
    "call",
    "case",
    "case_match",
    "chained_string",
    "character",
    "class",
    "command",
    "constant",
    "do_block",
    "element_reference",
    "elsif",
    "ensure",
    "false",
    "float",
    "for",
    "hash",
    "heredoc_beginning",
    "heredoc_body",
    "if",
    "if_modifier",
    "in_clause",
    "instance_variable",
    "integer",
    "lambda",
    "method",
    "module",
    "next",
    "nil",
    "operator_assignment",
    "range",
    "regex",
    "rescue",
    "rescue_modifier",
    "return",
    "scope_resolution",
    "simple_symbol",
    "singleton_method",
    "string",
    "string_array",
    "super",
    "symbol_array",
    "true",
    "unary",
    "undef",
    "unless",
    "unless_modifier",
    "until",
    "until_modifier",
    "when",
    "while",
    "while_modifier",
    "yield",
  }

  enum ParseStatus
    Ignore
    Error
    Ok
  end

  record ParseResult,
    status : ParseStatus,
    rule : String?,
    reason : String?,
    message : String?

  record SourceComment,
    start_byte : Int32,
    end_byte : Int32,
    content : String

  record TargetRange,
    start : Int32,
    finish : Int32

  class Directive
    getter rule : String
    getter reason : String
    getter path : String
    getter map : SourceMap
    getter start_byte : Int32
    getter end_byte : Int32
    getter scope_start : Int32
    getter scope_end : Int32
    property invalid : String?
    property used : Bool

    def initialize(
      @rule : String,
      @reason : String,
      @path : String,
      @map : SourceMap,
      @start_byte : Int32,
      @end_byte : Int32,
      @scope_start : Int32,
      @scope_end : Int32,
    )
      @invalid = nil
      @used = false
    end
  end

  def self.apply(index : ProjectIndex, diagnostics : Array(Diagnostic)) : Array(Diagnostic)
    directives = [] of Directive
    issues = [] of SourceIssue

    index.units.values.sort_by(&.file.relative_path).each do |unit|
      next unless unit.target?
      scan_ruby(unit, directives, issues)
    end
    index.target_templates.each do |view|
      scan_template(view, directives, issues)
    end

    mark_overlaps(directives)

    unsuppressible = [] of Diagnostic
    active = [] of Diagnostic
    diagnostics.each do |diagnostic|
      if UNSUPPRESSIBLE_RULES.includes?(diagnostic.rule)
        unsuppressible << diagnostic
      else
        active << diagnostic
      end
    end

    directives.each do |directive|
      next if directive.invalid
      remaining = [] of Diagnostic
      active.each do |diagnostic|
        if diagnostic.rule == directive.rule && in_scope?(diagnostic, directive)
          directive.used = true
        else
          remaining << diagnostic
        end
      end
      active = remaining
    end

    directives.each do |directive|
      if invalid = directive.invalid
        issues << issue(directive, invalid)
      elsif !directive.used
        message = if index.config.enabled?(directive.rule)
                    "suppression for '#{directive.rule}' does not suppress an enabled diagnostic"
                  else
                    "suppression for '#{directive.rule}' is unused because the rule is off"
                  end
        issues << issue(directive, message)
      end
    end

    suppression_diagnostics = issues.map { |source_issue| source_issue.diagnostic(Severity::Error) }
    Diagnostics.sort(unsuppressible + active + suppression_diagnostics)
  end

  private def self.in_scope?(diagnostic : Diagnostic, directive : Directive) : Bool
    diagnostic.start_byte >= directive.scope_start && diagnostic.end_byte <= directive.scope_end
  end

  private def self.issue(directive : Directive, message : String) : SourceIssue
    SourceIssue.new(
      directive.path,
      directive.map,
      directive.start_byte,
      directive.end_byte,
      message,
      Lint::SUPPRESSION_RULE,
    )
  end

  private def self.scan_ruby(
    unit : SourceUnit,
    directives : Array(Directive),
    issues : Array(SourceIssue),
  ) : Nil
    root = unit.root
    return unless root

    comments = [] of SourceComment
    constructs = [] of TreeSitter::Node
    collect_ruby(root, comments, constructs)
    comments.sort_by!(&.start_byte)
    constructs.sort_by! { |node| {node.start_byte, -node.end_byte} }

    comments.each do |comment|
      parsed = parse_directive(comment.content)
      next if parsed.status.ignore?

      if parsed.status.error?
        issues << comment_issue(unit.file.relative_path, unit.map, comment, parsed.message || "malformed suppression")
        next
      end

      rule = parsed.rule.not_nil!
      reason = parsed.reason.not_nil!
      if message = rule_error(rule)
        issues << comment_issue(unit.file.relative_path, unit.map, comment, message)
        next
      end

      limit = ruby_enclosing_limit(constructs, comment)
      target = constructs.find { |node| node.start_byte >= comment.end_byte && node.start_byte < limit }
      unless target
        issues << comment_issue(
          unit.file.relative_path,
          unit.map,
          comment,
          "suppression for '#{rule}' has no following Ruby construct",
        )
        next
      end

      directives << Directive.new(
        rule,
        reason,
        unit.file.relative_path,
        unit.map,
        comment.start_byte,
        comment.end_byte,
        target.start_byte,
        target.end_byte,
      )
    end
  end

  private def self.collect_ruby(
    node : TreeSitter::Node,
    comments : Array(SourceComment),
    constructs : Array(TreeSitter::Node),
  ) : Nil
    if node.type == "comment"
      comments << SourceComment.new(node.start_byte, node.end_byte, comment_body(node.text))
      return
    end

    constructs << node if RUBY_CONSTRUCT_TYPES.includes?(node.type)
    node.each_named_child { |child| collect_ruby(child, comments, constructs) }
  end

  private def self.comment_body(text : String) : String
    text.starts_with?("#") ? text.lchop("#").strip : text.strip
  end

  private def self.ruby_enclosing_limit(constructs : Array(TreeSitter::Node), comment : SourceComment) : Int32
    enclosing = constructs
      .select { |node| node.start_byte < comment.start_byte && comment.end_byte <= node.end_byte }
      .min_by? { |node| node.end_byte - node.start_byte }
    enclosing ? enclosing.end_byte : Int32::MAX
  end

  private def self.scan_template(
    view : TemplateView,
    directives : Array(Directive),
    issues : Array(SourceIssue),
  ) : Nil
    comments = template_comments(view.text)
    targets = template_targets(view)

    comments.each do |comment|
      parsed = parse_directive(comment.content)
      next if parsed.status.ignore?

      comment_start = source_byte(view, comment.start_byte)
      comment_end = source_byte(view, comment.end_byte)
      if parsed.status.error?
        issues << SourceIssue.new(
          view.unit_path,
          view.map,
          comment_start,
          comment_end,
          parsed.message || "malformed suppression",
          Lint::SUPPRESSION_RULE,
        )
        next
      end

      rule = parsed.rule.not_nil!
      reason = parsed.reason.not_nil!
      if message = rule_error(rule)
        issues << SourceIssue.new(
          view.unit_path,
          view.map,
          comment_start,
          comment_end,
          message,
          Lint::SUPPRESSION_RULE,
        )
        next
      end

      limit = template_enclosing_limit(targets, comment, view.text.bytesize)
      target = targets.find { |candidate| candidate.start >= comment.end_byte && candidate.start < limit }
      unless target
        issues << SourceIssue.new(
          view.unit_path,
          view.map,
          comment_start,
          comment_end,
          "suppression for '#{rule}' has no following template element or block",
          Lint::SUPPRESSION_RULE,
        )
        next
      end

      directives << Directive.new(
        rule,
        reason,
        view.unit_path,
        view.map,
        comment_start,
        comment_end,
        source_byte(view, target.start),
        source_byte(view, target.finish),
      )
    end
  end

  private def self.source_byte(view : TemplateView, offset : Int32) : Int32
    return view.literal_end_byte if offset >= view.text.bytesize
    view.source_byte(offset)
  end

  private def self.template_comments(text : String) : Array(SourceComment)
    comments = [] of SourceComment
    index = 0
    while index < text.bytesize
      case text.byte_at(index)
      when 60_u8 # <
        if comment_start?(text, index)
          ending = text.byte_index("-->", index + 4)
          if ending
            comments << SourceComment.new(
              index,
              ending + 3,
              text.byte_slice(index + 4, ending - index - 4),
            )
            index = ending + 3
          else
            index += 1
          end
        else
          index += 1
        end
      when 123_u8 # {
        if index + 1 < text.bytesize && text.byte_at(index + 1) == 123_u8
          index += 2
        else
          close = TemplateExpressionParser.matching_brace(text, index)
          index = close ? close + 1 : index + 1
        end
      else
        index += 1
      end
    end
    comments
  end

  private def self.template_targets(view : TemplateView) : Array(TargetRange)
    parser = TemplateExpressionParser.new
    document = Lint::TemplateElements.scan(view.text, parser)
    targets = document.elements.map do |element|
      TargetRange.new(element.start, element.end_byte || element.finish)
    end
    targets.concat(structural_blocks(view.text))
    targets.sort_by! { |target| {target.start, target.finish} }
    targets
  end

  private def self.structural_blocks(text : String) : Array(TargetRange)
    ranges = [] of TargetRange
    stack = [] of Int32
    index = 0

    while index < text.bytesize
      case text.byte_at(index)
      when 60_u8 # <
        if comment_start?(text, index)
          ending = text.byte_index("-->", index + 4)
          index = ending ? ending + 3 : text.bytesize
        else
          index += 1
        end
      when 123_u8 # {
        if index + 1 < text.bytesize && text.byte_at(index + 1) == 123_u8
          index += 2
        else
          close = TemplateExpressionParser.matching_brace(text, index)
          unless close
            index += 1
            next
          end

          source = text.byte_slice(index + 1, close - index - 1).strip
          if structural_open?(source)
            stack << index
          elsif source == "end"
            if start = stack.pop?
              ranges << TargetRange.new(start, close + 1)
            end
          end
          index = close + 1
        end
      else
        index += 1
      end
    end

    ranges
  end

  private def self.structural_open?(source : String) : Bool
    source.matches?(/\A(?:each|if|unless|with)\b/)
  end

  private def self.template_enclosing_limit(
    targets : Array(TargetRange),
    comment : SourceComment,
    text_bytesize : Int32,
  ) : Int32
    enclosing = targets
      .select { |target| target.start < comment.start_byte && comment.end_byte <= target.finish }
      .min_by? { |target| target.finish - target.start }
    enclosing ? enclosing.finish : text_bytesize
  end

  private def self.comment_start?(text : String, index : Int32) : Bool
    text.byte_slice(index, Math.min(4, text.bytesize - index)) == "<!--"
  end

  private def self.comment_issue(
    path : String,
    map : SourceMap,
    comment : SourceComment,
    message : String,
  ) : SourceIssue
    SourceIssue.new(
      path,
      map,
      comment.start_byte,
      comment.end_byte,
      message,
      Lint::SUPPRESSION_RULE,
    )
  end

  private def self.rule_error(rule : String) : String?
    return "unknown lint rule '#{rule}' in suppression directive" unless RuleRegistry[rule]?
    return "rule '#{rule}' cannot be suppressed" if UNSUPPRESSIBLE_RULES.includes?(rule)
    nil
  end

  private def self.parse_directive(content : String) : ParseResult
    trimmed = content.strip
    return parse_result(ParseStatus::Ignore, message: nil) unless trimmed.starts_with?("mochi-lint")
    return parse_error("malformed suppression; use disable-next RULE -- reason") unless trimmed.starts_with?(PREFIX)

    rest = trimmed[PREFIX.size..].strip
    if rest == "disable-next"
      return parse_error("suppression requires one rule id; use disable-next RULE -- reason")
    elsif rest.starts_with?("disable-next ")
      arguments = rest["disable-next ".size..].strip
      return parse_error("suppression requires one rule id; use disable-next RULE -- reason") if arguments.empty?

      separator = arguments.index("--")
      unless separator
        rule = arguments.strip
        return parse_error("suppression for '#{rule}' requires a nonempty reason after '--'")
      end

      rule = arguments[0...separator].strip
      reason = arguments[(separator + 2)..].strip
      return parse_error("suppression requires one rule id; use disable-next RULE -- reason") if rule.empty?
      if rule.in?("*", "all", "all-rules") || rule.includes?("*") || rule.includes?(",")
        return parse_error("suppression must name one rule; wildcard and all-rule directives are not allowed")
      end
      if rule.matches?(/\s/)
        return parse_error("suppression must name one rule; wildcard and all-rule directives are not allowed")
      end
      if reason.empty?
        return parse_error("suppression for '#{rule}' requires a nonempty reason after '--'")
      end
      ParseResult.new(ParseStatus::Ok, rule, reason, nil)
    elsif rest.starts_with?("disable")
      parse_error("file-wide suppression is not allowed; use disable-next RULE -- reason")
    else
      parse_error("malformed suppression; use disable-next RULE -- reason")
    end
  end

  private def self.parse_error(message : String) : ParseResult
    parse_result(ParseStatus::Error, message: message)
  end

  private def self.parse_result(
    status : ParseStatus,
    rule : String? = nil,
    reason : String? = nil,
    message : String? = nil,
  ) : ParseResult
    ParseResult.new(status, rule, reason, message)
  end

  private def self.mark_overlaps(directives : Array(Directive)) : Nil
    groups = {} of Tuple(String, String) => Array(Directive)
    directives.each do |directive|
      next if directive.invalid
      key = {directive.path, directive.rule}
      if group = groups[key]?
        group << directive
      else
        groups[key] = [directive]
      end
    end

    groups.each_value do |group|
      group.each_with_index do |left, left_index|
        group.each_with_index do |right, right_index|
          next unless right_index > left_index
          next unless overlap?(left, right)

          message = if left.scope_start == right.scope_start && left.scope_end == right.scope_end
                      "duplicate suppression for '#{left.rule}' on the same target"
                    else
                      "overlapping suppression for '#{left.rule}' targets nested scopes"
                    end
          left.invalid = message unless left.invalid
          right.invalid = message unless right.invalid
        end
      end
    end
  end

  private def self.overlap?(left : Directive, right : Directive) : Bool
    left.scope_start < right.scope_end && right.scope_start < left.scope_end
  end
end
