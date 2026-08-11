# Measures two generated parser modules against each other in one VM.
#
#     BENCH_EBIN=<dir> mix run bench/ab.exs
#
# Expects BenchOld and BenchNew, as produced by bench/gen_module.exs. With only
# BenchNew on the path it reports that side's absolute numbers instead.
# bench/compare.sh drives the whole thing; run this directly only if you have
# already built the modules yourself.
#
# The beam directory arrives by env var rather than `elixir -pa`, because Mix
# prunes the code path down to the project's own load paths.
#
# Env: BENCH_EBIN, BENCH_ROUNDS (default 21), BENCH_BUDGET_US per round (20000).
Code.require_file("support.exs", __DIR__)

if ebin = System.get_env("BENCH_EBIN"), do: Code.prepend_path(ebin)

alias Bench.{Measure, Table}

rounds = System.get_env("BENCH_ROUNDS", "21") |> String.to_integer()
budget = System.get_env("BENCH_BUDGET_US", "20000") |> String.to_integer()

old? = Code.ensure_loaded?(BenchOld)
if not Code.ensure_loaded?(BenchNew), do: raise("BenchNew is not on the code path")

call = fn module, parser, input -> fn -> apply(module, parser, [input]) end end

rows =
  for {label, parser, input} <- Bench.Cases.inputs() do
    new = call.(BenchNew, parser, input)

    # One iteration count for both sides, so the reduction counts stay directly
    # comparable
    iters = Measure.calibrate(new, budget)

    if old? do
      old = call.(BenchOld, parser, input)

      if apply(BenchOld, parser, [input]) != apply(BenchNew, parser, [input]) do
        raise "#{label}: the two revisions disagree on the result"
      end

      t_old = Measure.time(old, iters, rounds)
      t_new = Measure.time(new, iters, rounds)
      # The control: the same code timed twice. Its distance from 1.000x is how
      # much of the speedup column is noise.
      t_control = Measure.time(old, iters, rounds)

      r_old = Measure.reductions(old)
      r_new = Measure.reductions(new)

      [
        label,
        Table.ns(t_old),
        Table.ns(t_new),
        Table.ratio(t_old / t_new),
        Table.ratio(t_old / t_control),
        Table.int(r_old),
        Table.signed(r_new - r_old)
      ]
    else
      [label, Table.ns(Measure.time(new, iters, rounds)), Table.int(Measure.reductions(new))]
    end
  end

IO.puts("")

if old? do
  Table.print(["case", "old(ns)", "new(ns)", "speedup", "control", "red.", "red.diff"], rows)

  IO.puts("""

  speedup   old/new wall clock, min-of-#{rounds}. Only trust it if it clears `control`.
  control   the old side timed twice. This run's noise floor.
  red.diff  reductions for one call, new minus old. Exact: 0 means both revisions
            perform exactly the same work, whatever the clock says.
  """)
else
  Table.print(["case", "ns/call", "red./call"], rows)
  IO.puts("\nBenchOld not on the path, so this is the working tree alone.\n")
end
