defmodule FornacastAPI.PathValueTest do
  use ExUnit.Case, async: true

  test "slash values decode once without accepting traversal or ambiguous encodings" do
    for segments <- [["feature", "api"], ["feature%2Fapi"]] do
      assert {:ok, "feature/api"} = FornacastAPI.PathValue.decode(segments, "Reference", "ref")
    end

    for segments <- [
          ["%"],
          ["%GG"],
          ["%252F"],
          ["%25"],
          [".."],
          ["a", "..", "b"],
          ["%2e%2e"],
          ["/etc"],
          ["a\\b"],
          ["%00"],
          [<<255>>],
          ["e\u0301"],
          [""]
        ] do
      assert {:error, {:validation, [%{resource: "Reference", field: "ref", code: :invalid}]}} =
               FornacastAPI.PathValue.decode(segments, "Reference", "ref")
    end
  end

  test "the contents root may be empty without making a required ref optional" do
    assert {:ok, ""} = FornacastAPI.PathValue.decode([], "Content", "path")
    assert {:error, {:validation, _}} = FornacastAPI.PathValue.decode([], "Reference", "ref")
  end
end
