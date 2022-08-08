defmodule PagedFile.Bench do
  @moduledoc false
  def test(module, opts) do
    File.rm("test_file_rand")

    {:ok, fp} = module.open("test_file_rand", opts)

    offset = 4

    for x <- 0..10_000 do
      y =
        if x == 0 do
          1
        else
          {:ok, <<y::unsigned-size(32)>>} = module.pread(fp, (x - 1) * offset, 4)
          y
        end

      :ok = module.pwrite(fp, x * offset, <<y + x::unsigned-size(32)>>)
    end

    :ok = module.close(fp)
  end

  def run(%{modules: modules, rounds: rounds}, label, fun) do
    for {module, opts} <- modules do
      IO.puts("running #{label} test: #{inspect({module, opts})}")

      for _ <- 1..rounds do
        {time, :ok} = :timer.tc(fun, [module, opts])
        IO.puts("#{div(time, 1000) / 1000}s")
      end
    end
  end

  def run() do
    modules = [
      {:file, [:read, :write, :binary]},
      {:file, [:read, :read_ahead, :write, :delayed_write, :binary]},
      {PagedFile, []}
    ]

    rounds = 3
    context = %{modules: modules, rounds: rounds}

    run(context, "read-modify-write", &test/2)
  end
end
