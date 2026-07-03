defmodule FornacastTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "storage paths resolve under the configured repository root", %{tmp_dir: tmp_dir} do
    original = Application.get_env(:fornacast, :repo_storage_root)
    Application.put_env(:fornacast, :repo_storage_root, tmp_dir)

    try do
      assert Fornacast.Storage.repository_path!("@hashed/aa/bb/repo.git") ==
               Path.join([tmp_dir, "@hashed", "aa", "bb", "repo.git"])

      assert_raise ArgumentError, fn ->
        Fornacast.Storage.repository_path!("../repo.git")
      end
    after
      Application.put_env(:fornacast, :repo_storage_root, original)
    end
  end
end
