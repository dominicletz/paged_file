defmodule PagedFile do
  @moduledoc """
  Abstraction around `File` and `:file` allowing reads and writes
  while using a given page_size for buffering. This makes especially
  many `:pread`/`:pwrite` calls much faster

  # Example

  ```
  {:ok, fp} = PagedFile.open("test_file")
  :ok = PagedFile.pwrite(fp, 10, "hello")
  {:ok, "hello"} = PagedFile.pread(fp, 10, 5)
  :ok = PagedFile.close(fp)
  ```

  """
  use GenServer
  defstruct [:fp, :filename, :page_size, :max_pages, :pages, :dirty_pages, :filesize]

  @doc """

  Opens file File. Files are always opened for `:read` and `:write` and in `:binary` mode.
  The underlying usage of pages and memory can be controlled with the following options:any()

  - `page_size` - The default page size of loading disk data into memory and writing it back again.
  - `max_pages` - The maximum number of pages that should be kept in memory.

  """
  @spec open(binary | list(), keyword) :: {:ok, pid}
  def open(filename, args \\ []) do
    # default 0.5mb page size with 250 pages max (up to 125mb)
    page_size = Keyword.get(args, :page_size, 512_000)
    max_pages = Keyword.get(args, :max_pages, 250)

    {:ok, fp} = :file.open(filename, [:read, :write, :binary])

    state = %PagedFile{
      fp: fp,
      filename: filename,
      page_size: page_size,
      max_pages: max_pages,
      filesize: File.stat!(filename).size,
      pages: %{},
      dirty_pages: MapSet.new()
    }

    GenServer.start_link(__MODULE__, state, hibernate_after: 5_000)
  end

  @doc """
  Performs a sequence of `pread/3` in one operation, which is more efficient than
  calling them one at a time. Returns `{ok, [Data, ...]}`,
  where each Data, the result of the corresponding pread, is a binary or `:eof`
  if the requested position is beyond end of file.
  """
  @spec pread(atom | pid, [{integer(), integer()}]) :: {:ok, [binary() | :eof]}
  def pread(pid, locnums) do
    {:ok, call(pid, {:pread, locnums})}
  end

  @spec pread(atom | pid, integer(), integer()) :: {:ok, binary()} | :eof
  @doc """
  Executes are of `num` bytes at the position `loc`.
  """
  def pread(pid, loc, num) do
    case call(pid, {:pread, [{loc, num}]}) do
      [bin] when is_binary(bin) -> {:ok, bin}
      [:eof] -> :eof
      [error] when is_atom(error) -> {:error, error}
    end
  end

  @doc """
  Performs a sequence of `pwrite/3` in one operation, which is more efficient
  than calling them one at a time. Returns `:ok`.
  """
  @spec pwrite(atom | pid, [{integer(), binary()}]) :: :ok
  def pwrite(pid, locnums), do: GenServer.cast(pid, {:pwrite, locnums})

  @doc """
  Writes `data` to the position `loc` in the file. This is call is executed
  asynchrounosly and the file size is extended if needed to complete this call.
  """
  @spec pwrite(atom | pid, integer(), binary()) :: :ok
  def pwrite(pid, loc, data), do: pwrite(pid, [{loc, data}])

  @doc """
  Ensures that any all pages that have changes are written to disk.
  """
  @spec sync(atom | pid) :: :ok
  def sync(pid) do
    call(pid, :sync)
  end

  @doc false
  def info(pid) do
    call(pid, :info)
  end

  @doc """
  Writes all pending changes to disk and closes the file.
  """
  @spec close(atom | pid) :: :ok
  def close(pid) do
    sync(pid)
    GenServer.stop(pid)
  end

  @spec delete(atom | binary | [atom | list | char]) :: :ok | {:error, atom}
  @doc """
  Deletes the given file. Same as `:file.delete(filename)`
  """
  def delete(filename) do
    :file.delete(filename)
  end

  defp call(pid, cmd) do
    GenServer.call(pid, cmd, :infinity)
  end

  @impl true
  @doc false
  def init(state = %PagedFile{}) do
    {:ok, state}
  end

  @impl true
  def handle_call(:sync, _from, state = %PagedFile{}) do
    {:reply, :ok, flush_dirty_pages(state)}
  end

  def handle_call(:info, _from, state = %PagedFile{}) do
    {:reply, state, state}
  end

  def handle_call({:pread, locnums}, _from, state = %PagedFile{}) do
    {rets, state} =
      Enum.reduce(locnums, {[], state}, fn {loc, num}, {rets, state} ->
        {ret, state} = do_read(state, loc, num)
        {rets ++ [ret], state}
      end)

    {:reply, rets, state}
  end

  def handle_call({:pwrite, locnums}, _from, state = %PagedFile{}) do
    {rets, state} =
      Enum.reduce(locnums, {[], state}, fn {loc, data}, {rets, state} ->
        {ret, state} = do_write(state, loc, data)
        {rets ++ [ret], state}
      end)

    {:reply, rets, state}
  end

  def handle_call(:sync, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:pwrite, locnums}, state = %PagedFile{}) do
    state =
      Enum.reduce(locnums, state, fn {loc, data}, state ->
        {_ret, state} = do_write(state, loc, data)
        state
      end)

    {:noreply, state}
  end

  defp do_read(state = %PagedFile{filesize: filesize}, loc, _num) when loc >= filesize do
    {:eof, state}
  end

  defp do_read(state = %PagedFile{page_size: page_size, filesize: filesize}, loc, num) do
    page_idx = div(loc, page_size)
    page_start = rem(loc, page_size)

    state = %PagedFile{pages: pages} = load_page(state, page_idx)
    num = min(filesize - loc, num)

    ram_file = Map.get(pages, page_idx)
    {:ok, data} = :file.pread(ram_file, page_start, num)

    if byte_size(data) < num do
      {rest, state} = do_read(state, (page_idx + 1) * page_size, num - byte_size(data))
      {data <> rest, state}
    else
      {data, state}
    end
  end

  defp do_write(
         state = %PagedFile{page_size: page_size},
         loc,
         data
       ) do
    page_idx = div(loc, page_size)
    page_start = rem(loc, page_size)

    state =
      %PagedFile{pages: pages, dirty_pages: dirty_pages, filesize: filesize} =
      load_page(state, page_idx)

    write_len = min(page_size - page_start, byte_size(data))

    ram_file = Map.get(pages, page_idx)
    :ok = :file.pwrite(ram_file, page_start, binary_part(data, 0, write_len))

    state = %PagedFile{
      state
      | filesize: max(filesize, page_size * page_idx + page_start + write_len),
        dirty_pages: MapSet.put(dirty_pages, page_idx)
    }

    if write_len < byte_size(data) do
      do_write(
        state,
        (page_idx + 1) * page_size,
        binary_part(data, write_len, byte_size(data) - write_len)
      )
    else
      {:ok, state}
    end
  end

  defp load_page(state = %PagedFile{pages: pages, page_size: page_size, fp: fp}, page_idx) do
    if Map.get(pages, page_idx) != nil do
      state
    else
      page =
        case :file.pread(fp, page_idx * page_size, page_size) do
          {:ok, page} -> page
          # loading pages beyond physical boundaries, because of pwrites
          # that made the file longer
          :eof -> ""
        end

      delta = page_size - byte_size(page)
      page = page <> :binary.copy(<<0>>, delta)
      {:ok, page} = :file.open(page, [:ram, :read, :write, :binary])
      state = %PagedFile{pages: pages} = flush_pages(state)
      %PagedFile{state | pages: Map.put(pages, page_idx, page)}
    end
  end

  defp flush_pages(state = %PagedFile{pages: pages, max_pages: max_pages}) do
    if map_size(pages) > max_pages do
      count = trunc(map_size(pages) / 10) + 1

      Map.keys(pages)
      |> Enum.take(count)
      |> Enum.reduce(state, fn page_idx, state -> flush_page(state, page_idx) end)
    else
      state
    end
  end

  defp flush_dirty_pages(state = %PagedFile{dirty_pages: dirty_pages}) do
    Enum.reduce(dirty_pages, state, fn page_idx, state -> flush_page(state, page_idx) end)
  end

  defp flush_page(
         state = %PagedFile{
           pages: pages,
           dirty_pages: dirty_pages,
           fp: fp,
           filesize: filesize,
           page_size: page_size
         },
         page_idx
       ) do
    {page, pages} = Map.pop(pages, page_idx)

    dirty_pages =
      if MapSet.member?(dirty_pages, page_idx) do
        loc = page_idx * page_size
        num = min(filesize - loc, page_size)
        {:ok, data} = :file.pread(page, 0, num)
        :file.pwrite(fp, loc, data)
        MapSet.delete(dirty_pages, page_idx)
      else
        dirty_pages
      end

    :file.close(page)
    %PagedFile{state | pages: pages, dirty_pages: dirty_pages}
  end
end
