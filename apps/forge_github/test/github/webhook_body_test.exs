defmodule ForgeGitHub.WebhookBodyTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.Webhook

  test "retains long supported issue and comment bodies within the raw payload bound" do
    for resource <- ["issue", "comment"] do
      assert {:ok, %{installation_id: 1}} =
               decode(resource, "body", String.duplicate("界", 65_536))
    end
  end

  test "extended string budget is restricted to top-level collaboration bodies" do
    long = String.duplicate("x", 16_385)
    assert {:error, :json_too_complex} = decode("issue", "title", long)
    assert {:error, :json_too_complex} = decode("repository", "body", long)
    assert {:error, :json_too_complex} = decode("issue", "nested", %{"body" => long})
    assert {:error, :json_too_complex} = decode("issue", "nested", [%{"body" => long}])
  end

  test "body limits count codepoints and still reject NUL bytes" do
    assert {:error, :json_too_complex} = decode("issue", "body", String.duplicate("x", 65_537))

    assert {:error, :json_too_complex} =
             decode("comment", "body", String.duplicate("e\u0301", 32_769))

    assert {:error, :nul_byte} = decode("issue", "body", "text\u0000")
  end

  defp decode(resource, field, value) do
    %{"installation" => %{"id" => 1}, resource => %{field => value}}
    |> JSON.encode!()
    |> Webhook.decode_payload(1_048_576)
  end
end
