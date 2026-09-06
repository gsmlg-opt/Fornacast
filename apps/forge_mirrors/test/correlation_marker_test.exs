defmodule ForgeMirrors.CorrelationMarkerTest do
  use ExUnit.Case, async: true

  alias ForgeMirrors.CorrelationMarker

  @id "ac36ea90-98c4-4208-9ae1-3a85326dfc10"
  @other "0847b569-ae6c-4f56-a9f6-236d39ee92f2"

  test "outbound source has a stable hidden marker and round trips body whitespace" do
    for body <- ["", "Hello", "界\n\n", "<!-- unrelated -->\n"] do
      assert {:ok, encoded} = CorrelationMarker.append(body, @id)
      assert String.ends_with?(encoded, "<!-- fornacast:sync:v1:#{@id} -->")
      assert CorrelationMarker.matches?(encoded, @id)
      assert CorrelationMarker.strip(encoded, @id) == body
      assert CorrelationMarker.append(encoded, @id) == {:ok, encoded}
    end
  end

  test "only the persisted expected correlation marker is removed" do
    assert {:ok, encoded} = CorrelationMarker.append("Text", @other)
    assert CorrelationMarker.strip(encoded, @id) == encoded
    refute CorrelationMarker.matches?(encoded, @id)
    assert CorrelationMarker.strip(nil, @id) == nil
    refute CorrelationMarker.matches?(nil, @id)
    interior = encoded <> "\nUser text"
    assert CorrelationMarker.strip(interior, @other) == interior
  end

  test "nil bodies produce an empty source body plus marker" do
    assert {:ok, encoded} = CorrelationMarker.append(nil, @id)
    assert CorrelationMarker.strip(encoded, @id) == ""
  end

  test "invalid identities and bodies cannot introduce arbitrary marker source" do
    assert CorrelationMarker.append("body", "--> injected") == {:error, :invalid_correlation_id}
    assert CorrelationMarker.append(%{}, @id) == {:error, :invalid_body}
    assert CorrelationMarker.strip("body", "invalid") == "body"
    refute CorrelationMarker.matches?("body", "invalid")
  end

  test "the marker counts against the bounded provider body budget" do
    assert {:ok, suffix} = CorrelationMarker.append("", @id)
    body = String.duplicate("界", 65_536 - String.length(suffix))
    assert {:ok, encoded} = CorrelationMarker.append(body, @id)
    assert String.length(encoded) == 65_536
    assert CorrelationMarker.append(body <> "x", @id) == {:error, :body_too_long}

    assert CorrelationMarker.append(String.duplicate("e\u0301", 32_768), @id) ==
             {:error, :body_too_long}
  end
end
