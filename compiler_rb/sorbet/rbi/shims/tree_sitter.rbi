# typed: true
# frozen_string_literal: true

module TreeSitter
  class InstanceVarAnalyzer
    class Category < T::Enum
      enums do
        State = new
        Constant = new
        Derived = new
      end
    end

    class VariableInfo < T::Struct
      const :name, String
      prop :writes, Integer, default: 0
      prop :reads, Integer, default: 0
      prop :is_bound, T::Boolean, default: false
      prop :attr_mutated, T::Boolean, default: false
      prop :initialized_in_constructor, T::Boolean, default: false
      prop :written_outside_constructor, T::Boolean, default: false

      sig { returns(Category) }
      def category; end
    end

    sig { params(code: String).returns(T::Array[VariableInfo]) }
    def self.analyze(code); end
  end
end
