# typed: true
# frozen_string_literal: true

require "cli/parser"
require "formula"

module Homebrew
  module_function

  sig { returns(CLI::Parser) }
  def generate_formula_api_args
    Homebrew::CLI::Parser.new do
      description <<~EOS
        Generates Formula API data files for formulae.brew.sh.

        The generated files are written to the current directory.
      EOS

      switch "-n", "--dry-run", description: "Generate API data without writing it to files."

      named_args :none
    end
  end

  FORMULA_JSON_TEMPLATE = <<~EOS
    ---
    layout: formula_json
    ---
    {{ content }}
  EOS

  def html_template(title)
    <<~EOS
      ---
      title: #{title}
      layout: formula
      redirect_from: /formula-linux/#{title}
      ---
      {{ content }}
    EOS
  end

  def generate_formula_api
    args = generate_formula_api_args.parse

    tap = CoreTap.instance
    raise TapUnavailableError, tap.name unless tap.installed?

    unless args.dry_run?
      directories = ["_data/formula", "api/formula", "formula"]
      FileUtils.rm_rf directories + ["_data/formula_canonical.json"]
      FileUtils.mkdir_p directories
    end

    Homebrew.with_no_api_env do
      Formulary.enable_factory_cache!
      Formula.generating_hash!

      tap.formula_names.each do |name|
        formula = Formulary.factory(name)
        name = formula.name
        json = JSON.pretty_generate(formula.to_hash_with_variations)

        unless args.dry_run?
          File.write("_data/formula/#{name.tr("+", "_")}.json", "#{json}\n")
          File.write("api/formula/#{name}.json", FORMULA_JSON_TEMPLATE)
          File.write("formula/#{name}.html", html_template(name))
        end
      rescue
        onoe "Error while generating data for formula '#{name}'."
        raise
      end

      canonical_json = JSON.pretty_generate(tap.formula_renames.merge(tap.alias_table))
      File.write("_data/formula_canonical.json", "#{canonical_json}\n") unless args.dry_run?
    end
  end
end
