defmodule GitLFS.PointerTest do
  use ExUnit.Case, async: true

  alias GitLFS.Pointer

  @oid "4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393"

  test "parses the standard v1 pointer exactly" do
    pointer = """
    version https://git-lfs.github.com/spec/v1
    oid sha256:#{@oid}
    size 12345
    """

    assert {:ok, %Pointer{oid: @oid, size: 12_345}} = Pointer.parse(pointer)
  end

  test "accepts ordered extension lines while retaining their values" do
    pointer =
      "version https://git-lfs.github.com/spec/v1\n" <>
        "ext-0-example sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" <>
        "oid sha256:#{@oid}\n" <>
        "size 0\n"

    assert {:ok, %Pointer{oid: @oid, size: 0, extensions: extensions}} =
             Pointer.parse(pointer)

    assert extensions == [
             {"ext-0-example",
              "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
           ]
  end

  test "rejects malformed, oversized, duplicate, non-sha256, and noncanonical pointers" do
    invalid = [
      "",
      "version https://git-lfs.github.com/spec/v1\noid sha256:#{@oid}\n",
      "version https://git-lfs.github.com/spec/v1\noid sha512:#{@oid}\nsize 1\n",
      "version https://git-lfs.github.com/spec/v1\noid sha256:#{String.upcase(@oid)}\nsize 1\n",
      "version https://git-lfs.github.com/spec/v1\noid sha256:#{@oid}\nsize -1\n",
      "version https://git-lfs.github.com/spec/v1\noid sha256:#{@oid}\nsize 01\n",
      "version https://git-lfs.github.com/spec/v1\noid sha256:#{@oid}\noid sha256:#{@oid}\nsize 1\n",
      "version https://git-lfs.github.com/spec/v1\r\noid sha256:#{@oid}\r\nsize 1\r\n",
      String.duplicate("x", 1_025)
    ]

    for pointer <- invalid do
      assert {:error, :invalid_pointer} = Pointer.parse(pointer)
    end
  end

  test "does not inspect arbitrary terms or accept non-binaries" do
    assert {:error, :invalid_pointer} = Pointer.parse(%{payload: "secret"})
  end
end
