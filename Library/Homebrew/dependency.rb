# typed: true
# frozen_string_literal: true

require "dependable"

# A dependency on another Homebrew formula.
#
# @api private
class Dependency
  extend Forwardable
  include Dependable
  extend Cachable

  attr_reader :name, :env_proc, :option_names

  DEFAULT_ENV_PROC = proc {}.freeze
  private_constant :DEFAULT_ENV_PROC

  def initialize(name, tags = [], env_proc = DEFAULT_ENV_PROC, option_names = [name])
    raise ArgumentError, "Dependency must have a name!" unless name

    @name = name
    @tags = tags
    @env_proc = env_proc
    @option_names = option_names
  end

  def to_s
    name
  end

  def ==(other)
    instance_of?(other.class) && name == other.name && tags == other.tags
  end
  alias eql? ==

  def hash
    [name, tags].hash
  end

  def to_formula
    formula = Formulary.factory(name)
    formula.build = BuildOptions.new(options, formula.options)
    formula
  end

  def installed?
    to_formula.latest_version_installed?
  end

  def satisfied?(inherited_options = [])
    installed? && missing_options(inherited_options).empty?
  end

  def missing_options(inherited_options)
    formula = to_formula
    required = options
    required |= inherited_options
    required &= formula.options.to_a
    required -= Tab.for_formula(formula).used_options
    required
  end

  def modify_build_environment
    env_proc&.call
  end

  sig { returns(String) }
  def inspect
    "#<#{self.class.name}: #{name.inspect} #{tags.inspect}>"
  end

  # Define marshaling semantics because we cannot serialize @env_proc.
  def _dump(*)
    Marshal.dump([name, tags])
  end

  def self._load(marshaled)
    new(*Marshal.load(marshaled)) # rubocop:disable Security/MarshalLoad
  end

  sig { params(formula: Formula).returns(T.self_type) }
  def dup_with_formula_name(formula)
    self.class.new(formula.full_name.to_s, tags, env_proc, option_names)
  end

  class << self
    # Expand the dependencies of each dependent recursively, optionally yielding
    # `[dependent, dep]` pairs to allow callers to apply arbitrary filters to
    # the list.
    # The default filter, which is applied when a block is not given, omits
    # optionals and recommendeds based on what the dependent has asked for
    def expand(dependent, deps = dependent.deps, cache_key: nil, &block)
      # Keep track dependencies to avoid infinite cyclic dependency recursion.
      @expand_stack ||= []
      @expand_stack.push dependent.name

      if cache_key.present?
        cache[cache_key] ||= {}
        return cache[cache_key][cache_id dependent].dup if cache[cache_key][cache_id dependent]
      end

      expanded_deps = []

      deps.each do |dep|
        next if dependent.name == dep.name

        case action(dependent, dep, &block)
        when :prune
          next
        when :skip
          next if @expand_stack.include? dep.name

          expanded_deps.concat(expand(dep.to_formula, cache_key: cache_key, &block))
        when :keep_but_prune_recursive_deps
          expanded_deps << dep
        else
          next if @expand_stack.include? dep.name

          dep_formula = dep.to_formula
          expanded_deps.concat(expand(dep_formula, cache_key: cache_key, &block))

          # Fixes names for renamed/aliased formulae.
          dep = dep.dup_with_formula_name(dep_formula)
          expanded_deps << dep
        end
      end

      expanded_deps = merge_repeats(expanded_deps)
      cache[cache_key][cache_id dependent] = expanded_deps.dup if cache_key.present?
      expanded_deps
    ensure
      @expand_stack.pop
    end

    def action(dependent, dep, &block)
      catch(:action) do
        if block
          yield dependent, dep
        elsif dep.optional? || dep.recommended?
          prune unless dependent.build.with?(dep)
        end
      end
    end

    # Prune a dependency and its dependencies recursively.
    sig { void }
    def prune
      throw(:action, :prune)
    end

    # Prune a single dependency but do not prune its dependencies.
    sig { void }
    def skip
      throw(:action, :skip)
    end

    # Keep a dependency, but prune its dependencies.
    sig { void }
    def keep_but_prune_recursive_deps
      throw(:action, :keep_but_prune_recursive_deps)
    end

    def merge_repeats(all)
      grouped = all.group_by(&:name)

      all.map(&:name).uniq.map do |name|
        deps = grouped.fetch(name)
        dep  = deps.first
        tags = merge_tags(deps)
        option_names = deps.flat_map(&:option_names).uniq
        dep.class.new(name, tags, dep.env_proc, option_names)
      end
    end

    private

    def cache_id(dependent)
      "#{dependent.full_name}_#{dependent.class}"
    end

    def merge_tags(deps)
      other_tags = deps.flat_map(&:option_tags).uniq
      other_tags << :test if deps.flat_map(&:tags).include?(:test)
      merge_necessity(deps) + merge_temporality(deps) + other_tags
    end

    def merge_necessity(deps)
      # Cannot use `deps.any?(&:required?)` here due to its definition.
      if deps.any? { |dep| !dep.recommended? && !dep.optional? }
        [] # Means required dependency.
      elsif deps.any?(&:recommended?)
        [:recommended]
      else # deps.all?(&:optional?)
        [:optional]
      end
    end

    def merge_temporality(deps)
      # Means both build and runtime dependency.
      return [] unless deps.all?(&:build?)

      [:build]
    end
  end
end

# A dependency on another Homebrew formula in a specific tap.
class TapDependency < Dependency
  attr_reader :tap

  def initialize(name, tags = [], env_proc = DEFAULT_ENV_PROC, option_names = [name.split("/").last])
    @tap = Tap.fetch(name.rpartition("/").first)
    super(name, tags, env_proc, option_names)
  end

  def installed?
    super
  rescue FormulaUnavailableError
    false
  end
end
