# Dumps the parsers in Bench.Cases as plain, formatted source.
#
#     mix run bench/gen_module.exs <ModuleSuffix> <output.ex>
#
# Two purposes:
#
#   * The code two revisions generate can be compiled into a single VM and
#     measured side by side, without either paying for a recompile.
#   * The dumps are diffable. An empty diff settles a performance question
#     outright: identical code cannot run at different speeds. A non-empty one
#     still needs reading, since function numbering and clause order shift
#     around harmlessly.
Code.require_file("support.exs", __DIR__)

[suffix, out] = System.argv()

body =
  for {name, combinator} <- Bench.Cases.parsers() do
    {defs, inline} = NimbleParsec.Compiler.compile(name, Enum.reverse(combinator), inline: true)

    clauses =
      for {fun, args, guards, body} <- defs do
        head = Macro.to_string({fun, [], args})
        head = if guards == true, do: head, else: "#{head} when #{Macro.to_string(guards)}"
        "defp #{head} do\n#{Macro.to_string(body)}\nend"
      end

    # Calls the generated entry point directly, minus the `defparsec` wrapper's
    # argument handling
    """
    @compile {:inline, #{inspect(inline)}}
    def #{name}(binary), do: #{name}__0(binary, [], [], %{}, {1, 0}, 0)

    #{Enum.join(clauses, "\n\n")}
    """
  end

source = "defmodule Bench#{suffix} do\n#{Enum.join(body, "\n")}\nend\n"
File.write!(out, [Code.format_string!(source), "\n"])
IO.puts("wrote #{out} (Bench#{suffix})")
