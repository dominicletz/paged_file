# PagedFile

Faster file access for random read/write loads. 

# Note

This has been created to support [DetsPlus](https://github.com/dominicletz/dets_plus) and not to be fully `:file` compatible. The focus has been read-modify-write performance. The repo includes a quick test to compare the performance with the built-in `:file`. The first test is doing 100_000 read-modify-write calls, the second tests is just issuing many writes:

On average `PagedFile` is 3.5x faster than `:file` for these tasks and 2x faster than `:file.open(..., [:raw])` but 
without the restriction of `:raw` to a single process.


```
Compiling 1 file (.ex)
running read-modify-write test: {:file, [:read, :write, :binary]}
3.038s
3.092s
3.614s
running read-modify-write test: {:file, [:raw, :read, :write, :binary]}
1.461s
1.219s
1.198s
running read-modify-write test: {:file, [:read, :read_ahead, :write, :delayed_write, :binary]}
5.454s
5.139s
5.148s
running read-modify-write test: {:file, [:raw, :read, :read_ahead, :write, :delayed_write, :binary]}
2.061s
2.065s
2.027s
running read-modify-write test: {PagedFile, []}
0.69s
0.695s
0.686s
running writes test: {:file, [:read, :write, :binary]}
2.657s
2.528s
2.603s
running writes test: {:file, [:raw, :read, :write, :binary]}
1.313s
1.314s
1.174s
running writes test: {:file, [:read, :read_ahead, :write, :delayed_write, :binary]}
5.068s
5.129s
5.119s
running writes test: {:file, [:raw, :read, :read_ahead, :write, :delayed_write, :binary]}
1.612s
1.74s
1.906s
running writes test: {PagedFile, []}
0.745s
0.815s
0.715s
```

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

