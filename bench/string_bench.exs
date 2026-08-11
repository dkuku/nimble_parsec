# Absolute numbers for the working tree, through the public API.
#
#     mix run bench/string_bench.exs
#
# This goes through the parsers `defparsec` defines, wrapper and all, so the
# numbers are what a caller actually pays. For comparing two revisions use
# bench/compare.sh, which measures both in one VM and can prove when the
# generated code is identical.
#
# Env: BENCH_ROUNDS (default 21), BENCH_BUDGET_US per round (default 20000).
Code.require_file("support.exs", __DIR__)

alias Bench.{Measure, Table}

defmodule Bench.Parsers do
  import NimbleParsec

  # `defparsec` evaluates its combinator in the module body, so the shared
  # definitions can be fed to it straight from Bench.Cases
  for {name, combinator} <- Bench.Cases.parsers() do
    defparsec(name, combinator)
  end
end

rounds = System.get_env("BENCH_ROUNDS", "21") |> String.to_integer()
budget = System.get_env("BENCH_BUDGET_US", "20000") |> String.to_integer()

rows =
  for {label, parser, input} <- Bench.Cases.inputs() do
    fun = fn -> apply(Bench.Parsers, parser, [input]) end
    iters = Measure.calibrate(fun, budget)

    [
      label,
      Table.ns(Measure.time(fun, iters, rounds)),
      Table.ns(Measure.reductions(fun, 2_000))
    ]
  end

IO.puts("")
Table.print(~w(case ns/call red./call), rows)

IO.puts("""

ns/call    min-of-#{rounds} rounds, each in a fresh process.
red./call  reductions, including a constant loop overhead. Deterministic.
""")
