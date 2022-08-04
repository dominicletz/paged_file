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

  def run() do
    for {module, opts} <- [
          {:file, [:read, :write, :binary]},
          {:file, [:read, :read_ahead, :write, :delayed_write, :binary]},
          {PagedFile, []}
        ] do
      IO.puts("running #{inspect({module, opts})}")

      for _ <- 1..3 do
        {time, :ok} = :timer.tc(&test/2, [module, opts])
        IO.puts("#{time}μs")
      end
    end
  end
end
