defmodule PagedFile do
  @moduledoc """
  [PagedFile](https://github.com/dominicletz/paged_file) provides fast
  reads and writes by using multiple buffers of `page_size`. This makes
  many `:pread`/`:pwrite` calls faster. Especially useful for read-modify-write
  use cases.

  # Example

  ```
  {:ok, fp} = __MODULE__.open("test_file")
  :ok = __MODULE__.pwrite(fp, 10, "hello")
  {:ok, "hello"} = __MODULE__.pread(fp, 10, 5)
  :ok = __MODULE__.close(fp)
  ```

  """
  use GenServer
  defstruct [:fp, :filename, :page_size, :max_pages, :pages, :pq, :dirty_pages, :filesize]

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

    state = %__MODULE__{
      fp: fp,
      filename: filename,
      page_size: page_size,
      max_pages: max_pages,
      filesize: File.stat!(filename).size,
      pages: %{},
      pq: :queue.new(),
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
  def pwrite(pid, locnums) do
    send(pid, {:pwrite, locnums})
    :ok
  end

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
  def init(state = %__MODULE__{}) do
    {:ok, state}
  end

  @impl true
  def handle_call(:sync, _from, state = %__MODULE__{}) do
    {:reply, :ok, sync_dirty_pages(state)}
  end

  def handle_call(:info, _from, state = %__MODULE__{}) do
    {:reply, state, state}
  end

  def handle_call({:pread, locnums}, _from, state = %__MODULE__{}) do
    {rets, state} =
      Enum.reduce(locnums, {[], state}, fn {loc, num}, {rets, state} ->
        {ret, state} = do_read(state, loc, num)
        {rets ++ [ret], state}
      end)

    {:reply, rets, state}
  end

  def handle_call({:pwrite, locnums}, _from, state = %__MODULE__{}) do
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
  def handle_info({:pwrite, locnums}, state = %__MODULE__{}) do
    locnums = locnums ++ collect_pwrites()

    state =
      Enum.reduce(locnums, state, fn {loc, data}, state ->
        {_ret, state} = do_write(state, loc, data)
        state
      end)

    {:noreply, state}
  end

  defp collect_pwrites() do
    receive do
      message ->
        case message do
          {:pwrite, locnums} ->
            locnums ++ collect_pwrites()

          other ->
            send(self(), other)
            []
        end
    after
      0 -> []
    end
  end

  defp do_read(state = %__MODULE__{filesize: filesize}, loc, _num) when loc >= filesize do
    {:eof, state}
  end

  defp do_read(state = %__MODULE__{page_size: page_size, filesize: filesize}, loc, num) do
    page_idx = div(loc, page_size)
    page_start = rem(loc, page_size)

    state = %__MODULE__{pages: pages} = load_page(state, page_idx)
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
         state = %__MODULE__{page_size: page_size},
         loc,
         data
       ) do
    page_idx = div(loc, page_size)
    page_start = rem(loc, page_size)

    state =
      %__MODULE__{pages: pages, dirty_pages: dirty_pages, filesize: filesize} =
      load_page(state, page_idx)

    write_len = min(page_size - page_start, byte_size(data))

    ram_file = Map.get(pages, page_idx)
    :ok = :file.pwrite(ram_file, page_start, binary_part(data, 0, write_len))

    state = %__MODULE__{
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

  defp load_page(
         state = %__MODULE__{pages: pages, page_size: page_size, pq: pq, fp: fp},
         page_idx
       ) do
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
      state = %__MODULE__{pages: pages} = flush_pages(state)
      %__MODULE__{state | pages: Map.put(pages, page_idx, page), pq: :queue.in(page_idx, pq)}
    end
  end

  defp flush_pages(state = %__MODULE__{pages: pages, max_pages: max_pages}) do
    if map_size(pages) > max_pages do
      flush_page(state)
    else
      state
    end
  end

  defp sync_dirty_pages(state = %__MODULE__{dirty_pages: dirty_pages}) do
    Enum.reduce(dirty_pages, state, fn page_idx, state -> sync_page(state, page_idx) end)
  end

  defp sync_page(
         state = %__MODULE__{
           pages: pages,
           dirty_pages: dirty_pages,
           fp: fp,
           filesize: filesize,
           page_size: page_size
         },
         page_idx
       ) do
    loc = page_idx * page_size
    num = min(filesize - loc, page_size)
    {:ok, data} = :file.pread(Map.get(pages, page_idx), 0, num)
    :file.pwrite(fp, loc, data)
    dirty_pages = MapSet.delete(dirty_pages, page_idx)
    %__MODULE__{state | dirty_pages: dirty_pages}
  end

  defp flush_page(state = %__MODULE__{dirty_pages: dirty_pages, pq: pq}) do
    {:value, page_idx} = :queue.peek(pq)

    state =
      %__MODULE__{pages: pages, pq: ^pq} =
      if MapSet.member?(dirty_pages, page_idx) do
        sync_page(state, page_idx)
      else
        state
      end

    {page, pages} = Map.pop(pages, page_idx)
    {{:value, ^page_idx}, pq} = :queue.out(pq)
    :file.close(page)
    %__MODULE__{state | pages: pages, pq: pq}
  end
end
