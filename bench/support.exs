# Shared helpers for the benchmarks in this directory.
#
# Measurement notes, learned the hard way on this parser:
#
#   * The timing loop must not accumulate results. `for _ <- 1..n, do: fun.()`
#     builds a list of n return values, which makes GC timing rather than the
#     parser the thing being measured.
#   * Each round runs in a fresh process, so one round's heap cannot perturb
#     the next.
#   * min-of-N, because the fastest round is the one least perturbed by GC and
#     by the scheduler. Means and medians mostly measure the rest of the machine.
#   * Reductions are deterministic, but only if measured one call at a time.
#     See `Bench.Measure.reductions/2`. Measured that way, a reduction delta of
#     zero says the work performed is identical, which no amount of wall clock
#     measurement can establish.
#
# Always read the control column before believing a speedup. It times the same
# code in both slots, so whatever it reports is the noise floor of that run.

defmodule Bench.Measure do
  @moduledoc false

  @warmup 200

  def spin(_fun, 0), do: :ok

  def spin(fun, n) do
    fun.()
    spin(fun, n - 1)
  end

  @doc """
  Picks an iteration count that makes one round last roughly `budget_us`.

  Cases here span three orders of magnitude, so one hardcoded count would be
  either unmeasurably short or needlessly slow.
  """
  def calibrate(fun, budget_us) do
    spin(fun, 50)
    {us, _} = :timer.tc(fn -> spin(fun, 100) end)
    per_call = max(us / 100, 0.001)

    (budget_us / per_call) |> trunc() |> max(50) |> min(500_000)
  end

  @doc "Nanoseconds per call: the fastest of `rounds` rounds of `iters` calls."
  def time(fun, iters, rounds) do
    for _ <- 1..rounds do
      isolated(fn ->
        spin(fun, @warmup)
        {us, _} = :timer.tc(fn -> spin(fun, iters) end)
        us
      end)
    end
    |> Enum.min()
    |> Kernel.*(1000)
    |> Kernel./(iters)
  end

  @doc """
  Reductions for a single call, as an exact integer.

  One call per freshly spawned process, rather than a loop of calls divided by
  the iteration count. The loop version does not work: a process' reduction
  counter is only reconciled at scheduler yield boundaries, so once a run is
  long enough to yield, the per-call average lands a few reductions off and
  reports a fractional value for work that is necessarily whole.

  That error is systematic and reproduces bit for bit, which makes it easy to
  read as signal. It is what made a revision that removed a function call look
  0.78 reductions *worse* on a case where it is exactly one reduction better.

  Includes a small constant for the measurement scaffolding. It is identical on
  both sides of a comparison, so differences stay exact.

  Takes the minimum over `rounds`, since the first call into a module also pays
  to load its code.
  """
  def reductions(fun, rounds \\ 25) do
    for _ <- 1..rounds do
      isolated(fn ->
        {:reductions, before} = :erlang.process_info(self(), :reductions)
        fun.()
        {:reductions, later} = :erlang.process_info(self(), :reductions)
        later - before
      end)
    end
    |> Enum.min()
  end

  defp isolated(fun) do
    parent = self()
    ref = make_ref()
    pid = spawn(fn -> send(parent, {ref, fun.()}) end)
    monitor = Process.monitor(pid)

    receive do
      {^ref, result} ->
        receive do
          {:DOWN, ^monitor, _, _, _} -> result
        end
    after
      120_000 -> exit(:bench_timeout)
    end
  end
end

defmodule Bench.Table do
  @moduledoc false

  @doc "Prints a table with a left aligned first column and the rest right aligned."
  def print(header, rows) do
    widths =
      Enum.zip_with([header | rows], fn column ->
        column |> Enum.map(&String.length/1) |> Enum.max()
      end)

    for row <- [header | rows] do
      [{first, width} | rest] = Enum.zip(row, widths)

      IO.puts([
        String.pad_trailing(first, width)
        | Enum.map(rest, fn {cell, width} -> "  " <> String.pad_leading(cell, width) end)
      ])
    end
  end

  def ns(float), do: :erlang.float_to_binary(float, decimals: 1)
  def ratio(float), do: :erlang.float_to_binary(float, decimals: 3) <> "x"
  def int(integer), do: Integer.to_string(integer)

  def signed(integer) when is_integer(integer) do
    if integer > 0, do: "+" <> int(integer), else: int(integer)
  end
end

defmodule Bench.Cases do
  @moduledoc false

  @doc """
  The parsers under test, as `{name, combinator}`.

  Kept as data rather than as `defparsec` calls so the same definitions can be
  compiled by two different revisions of the library, or dumped as source.
  """
  def parsers do
    import NimbleParsec

    [
      ident: ascii_string([?a..?z], min: 1),
      opt: ascii_string([?a..?z], min: 0),
      bounded: ascii_string([?a..?z], min: 2, max: 8),
      u_ident: utf8_string([?a..?z], min: 1),
      words: repeat(ascii_string([?a..?z], min: 1) |> ignore(optional(string(","))))
    ]
  end

  @doc "The measured cases, as `{label, parser, input}`."
  def inputs do
    word = &String.duplicate("a", &1)
    doc = fn count, len -> Enum.map_join(1..count, ",", fn _ -> word.(len) end) end

    Enum.map([1, 4, 8, 32, 128, 1024], &{"ascii len=#{&1}", :ident, word.(&1)}) ++
      Enum.map([1, 128], &{"opt len=#{&1}", :opt, word.(&1)}) ++
      Enum.map([8, 128], &{"utf8 len=#{&1}", :u_ident, word.(&1)}) ++
      [
        {"bounded 2..8", :bounded, word.(6)},
        {"repeat 200x6ch", :words, doc.(200, 6)},
        {"repeat 200x40ch", :words, doc.(200, 40)},
        # The error path: fails the up-front `min` match
        {"error (min fail)", :ident, "!"}
      ]
  end
end
