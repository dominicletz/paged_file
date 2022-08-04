# PagedFile

Faster file access for random read/write loads. 

# Note

This has been created to support [DetsPlus](https://github.com/dominicletz/dets_plus) and not to be fully `:file` compatible. The focus has been read-modify-write performance. The repo includes a quick test to compare the performance with the built-in `:file`. The test is doing 10_000 read-modify-write calls:

```
$ mix run bench/paged_file.exs 
Compiling 1 file (.ex)
running {:file, [:read, :write, :binary]}
283007μs
299286μs
264135μs
running {:file, [:read, :read_ahead, :write, :delayed_write, :binary]}
583433μs
576405μs
551866μs
running {PagedFile, []}
81807μs
76203μs
77618μs
```

So on average `PagedFile` is 3.5x faster than `:file` for this task.

# Example usage

```
{:ok, fp} = PagedFile.open("test_file")
:ok = PagedFile.pwrite(fp, 10, "hello")
{:ok, "hello"} = PagedFile.pread(fp, 10, 5)
:ok = PagedFile.close(fp)
```

# Ideas for PRs

- Flush some pages after timeouts (auto_save)
- Allow parallel flushing of pages to disk while other operations continue.
- Optimize `read_only` file access by going around the GenServer and use an ETS table instead to look for the right ram_file and read that. - Maybe even faster
- Add location less `read()` / `write()` functions and manage an offset

## Installation

The package can be installed by adding `paged_file` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:paged_file, "~> 1.0.0"}
  ]
end
```

The docs can be found at [https://hexdocs.pm/paged_file](https://hexdocs.pm/paged_file).

