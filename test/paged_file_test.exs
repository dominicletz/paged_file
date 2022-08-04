defmodule PagedFile.Test do
  use ExUnit.Case, async: true

  describe "open_file" do
    test "check writing" do
      filename = "page_file_write_test"
      File.rm(filename)

      testset = [
        {0, "123"},
        {125, "1234567890"},
        {1000, "hello_world"}
      ]

      for {offset, test} <- testset do
        {:ok, fp} = PagedFile.open(filename, page_size: 128)
        assert PagedFile.pwrite(fp, offset, test) == :ok
        assert PagedFile.pread(fp, offset, byte_size(test)) == {:ok, test}
        assert PagedFile.sync(fp) == :ok
        assert PagedFile.pread(fp, offset, byte_size(test)) == {:ok, test}
        assert PagedFile.close(fp) == :ok

        # reopen test
        {:ok, fp} = PagedFile.open(filename, page_size: 128)
        assert PagedFile.pread(fp, offset, byte_size(test)) == {:ok, test}
        assert PagedFile.close(fp) == :ok

        # actual file test
        {:ok, fp} = :file.open(filename, [:read, :binary])
        assert :file.pread(fp, offset, byte_size(test)) == {:ok, test}
        :file.close(fp)
      end
    end

    test "check eof" do
      filename = "page_file_test_eof"

      testset = [
        {144, 10},
        {128 * 2, 10},
        {145, 10}
      ]

      for {offset, num} <- testset do
        File.rm(filename)
        {:ok, fp} = PagedFile.open(filename, page_size: 128)
        assert PagedFile.pwrite(fp, 140, "1234") == :ok

        assert PagedFile.pread(fp, offset, num) == :eof
        PagedFile.sync(fp)
        assert PagedFile.pread(fp, offset, num) == :eof
        PagedFile.close(fp)

        # actual file test
        {:ok, fp} = :file.open(filename, [:read, :binary])
        assert :file.pread(fp, offset, num) == :eof
        :file.close(fp)
      end
    end
  end
end
