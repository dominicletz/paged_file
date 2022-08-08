# PagedFile

Faster file access for random read/write loads. 

# Note

This has been created to support [DetsPlus](https://github.com/dominicletz/dets_plus) and not to be fully `:file` compatible. The focus has been read-modify-write performance. The repo includes a quick test to compare the performance with the built-in `:file`. The first test is doing 100_000 read-modify-write calls, the second tests is just issuing many writes:

```
running read-modify-write test: {:file, [:read, :write, :binary]}
3.05s
2.733s
2.822s
running read-modify-write test: {:file, [:read, :read_ahead, :write, :delayed_write, :binary]}
5.393s
5.29s
5.296s
running read-modify-write test: {PagedFile, []}
0.687s
0.708s
0.69s

running writes test: {:file, [:read, :write, :binary]}
2.574s
2.572s
2.643s
running writes test: {:file, [:read, :read_ahead, :write, :delayed_write, :binary]}
5.217s
5.169s
5.256s
running writes test: {PagedFile, []}
0.986s
0.844s
0.865s
```

So on average `PagedFile` is 3.5x faster than `:file` for these tasks.

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

