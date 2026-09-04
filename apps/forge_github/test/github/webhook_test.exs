defmodule ForgeGitHub.WebhookTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.Webhook

  @secret "It's a Secret to Everybody"
  @payload "Hello, World!"
  @digest "757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17"

  test "verifies GitHub's official HMAC SHA-256 example" do
    assert :ok =
             Webhook.verify_signature(
               @secret,
               @payload,
               "sha256=" <> @digest,
               byte_size(@payload)
             )
  end

  test "rejects modified payloads and signatures" do
    assert {:error, :invalid_signature} =
             Webhook.verify_signature(
               @secret,
               @payload <> ".",
               "sha256=" <> @digest,
               byte_size(@payload) + 1
             )

    modified_digest = String.replace_suffix(@digest, "17", "18")

    assert {:error, :invalid_signature} =
             Webhook.verify_signature(
               @secret,
               @payload,
               "sha256=" <> modified_digest,
               byte_size(@payload)
             )
  end

  test "accepts only the exact lowercase sha256 header format" do
    invalid_headers = [
      @digest,
      "sha256:#{@digest}",
      "SHA256=#{@digest}",
      "sha256=#{String.upcase(@digest)}",
      " sha256=#{@digest}",
      "sha256=#{@digest} ",
      "sha256=#{@digest}0",
      "sha256=#{String.slice(@digest, 0, 63)}"
    ]

    for header <- invalid_headers do
      assert {:error, :invalid_signature} =
               Webhook.verify_signature(@secret, @payload, header, byte_size(@payload))
    end
  end

  test "enforces the caller-provided raw body bound" do
    assert {:error, :body_too_large} =
             Webhook.verify_signature(@secret, @payload, "sha256=" <> @digest, 12)

    assert {:error, :invalid_body_limit} =
             Webhook.verify_signature(@secret, @payload, "sha256=" <> @digest, 0)

    assert {:error, :invalid_body} =
             Webhook.verify_signature(@secret, nil, "sha256=" <> @digest, 13)
  end

  test "uses the public constant-time comparison wrapper" do
    assert Webhook.secure_compare("same-length", "same-length")
    refute Webhook.secure_compare("same-length", "diff-length")
    refute Webhook.secure_compare("short", "longer")
    refute Webhook.secure_compare(nil, "longer")
  end

  test "verifies a valid signature before separately decoding JSON" do
    raw_body = JSON.encode!(%{"installation" => %{"id" => 123}})
    signature = signature(@secret, raw_body)

    assert :ok = Webhook.verify_signature(@secret, raw_body, signature, 1_024)

    assert {:ok, %{action: nil, installation_id: 123, repository_id: nil}} =
             Webhook.decode_payload(raw_body, 1_024)
  end

  test "keeps valid-signature and invalid-JSON results separate" do
    raw_body = ~s({"installation":{"id":123})
    signature = signature(@secret, raw_body)

    assert :ok = Webhook.verify_signature(@secret, raw_body, signature, 1_024)
    assert {:error, :invalid_json} = Webhook.decode_payload(raw_body, 1_024)
  end

  test "extracts bounded routing metadata from a top-level object" do
    raw_body =
      JSON.encode!(%{
        "action" => "edited",
        "installation" => %{"id" => 9_223_372_036_854_775_807},
        "repository" => %{"id" => 4_294_967_296},
        "unused" => %{"token" => "not-returned"}
      })

    assert {:ok,
            %{
              action: "edited",
              installation_id: 9_223_372_036_854_775_807,
              repository_id: 4_294_967_296
            }} = Webhook.decode_payload(raw_body, byte_size(raw_body))

    refute inspect(Webhook.decode_payload(raw_body, byte_size(raw_body))) =~ "not-returned"
  end

  test "rejects invalid body inputs without echoing their bytes" do
    assert {:error, :invalid_body_limit} = Webhook.decode_payload("{}", 0)
    assert {:error, :invalid_body} = Webhook.decode_payload(nil, 100)
    assert {:error, :body_too_large} = Webhook.decode_payload("{}", 1)
    assert {:error, :invalid_utf8} = Webhook.decode_payload(<<0xFF>>, 1)

    raw_body = ~s({"installation":{"id":123},"value":"secret\u0000bytes"})
    result = Webhook.decode_payload(raw_body, byte_size(raw_body))

    assert {:error, :nul_byte} = result
    refute inspect(result) =~ "secret"
  end

  test "requires a top-level object and one positive signed-bigint installation ID" do
    for body <- [
          "[]",
          "null",
          ~s({"installation":null}),
          ~s({"installation":{}}),
          ~s({"installation":{"id":0}}),
          ~s({"installation":{"id":-1}}),
          ~s({"installation":{"id":"1"}}),
          ~s({"installation":{"id":9223372036854775808}})
        ] do
      assert {:error, reason} = Webhook.decode_payload(body, byte_size(body))
      assert reason in [:invalid_payload, :invalid_installation_id]
    end
  end

  test "permits absent installation routing so authenticated unknown events can be ignored" do
    body = ~s({"future_payload":"value"})

    assert {:ok, %{action: nil, installation_id: nil, repository_id: nil}} =
             Webhook.decode_payload(body, byte_size(body))
  end

  test "accepts an absent or null repository and validates a present repository ID" do
    absent = ~s({"installation":{"id":1}})
    null = ~s({"installation":{"id":1},"repository":null})

    assert {:ok, %{repository_id: nil}} = Webhook.decode_payload(absent, byte_size(absent))
    assert {:ok, %{repository_id: nil}} = Webhook.decode_payload(null, byte_size(null))

    for repository <- [
          %{},
          %{"id" => 0},
          %{"id" => -1},
          %{"id" => "1"},
          %{"id" => 9_223_372_036_854_775_808}
        ] do
      body = JSON.encode!(%{"installation" => %{"id" => 1}, "repository" => repository})

      assert {:error, :invalid_repository_id} =
               Webhook.decode_payload(body, byte_size(body))
    end
  end

  test "accepts only an optional bounded action string" do
    for action <- [nil, "", 1, String.duplicate("x", 101)] do
      body = JSON.encode!(%{"action" => action, "installation" => %{"id" => 1}})

      assert {:error, :invalid_action} = Webhook.decode_payload(body, byte_size(body))
    end

    nul_action = JSON.encode!(%{"action" => "created\0suffix", "installation" => %{"id" => 1}})
    assert {:error, :nul_byte} = Webhook.decode_payload(nul_action, byte_size(nul_action))

    action = String.duplicate("a", 100)
    body = JSON.encode!(%{"action" => action, "installation" => %{"id" => 1}})
    assert {:ok, %{action: ^action}} = Webhook.decode_payload(body, byte_size(body))
  end

  test "bounds JSON depth, node count, collection size, strings, and keys" do
    too_deep = Enum.reduce(1..17, "leaf", fn _index, value -> [value] end)

    excessive_nodes =
      for outer <- 1..100 do
        for inner <- 1..512, do: outer * inner
      end

    payloads = [
      %{"installation" => %{"id" => 1}, "value" => too_deep},
      %{"installation" => %{"id" => 1}, "value" => excessive_nodes},
      %{"installation" => %{"id" => 1}, "value" => Enum.to_list(1..513)},
      %{"installation" => %{"id" => 1}, "value" => String.duplicate("x", 16_385)},
      %{
        "installation" => %{"id" => 1},
        String.duplicate("k", 129) => "value"
      }
    ]

    for payload <- payloads do
      body = JSON.encode!(payload)
      assert {:error, :json_too_complex} = Webhook.decode_payload(body, byte_size(body))
    end
  end

  test "marks only initial installation and inventory actions processable" do
    for action <- ~w(created new_permissions_accepted suspend unsuspend deleted) do
      assert :processable = Webhook.classify("installation", action)
    end

    for action <- ~w(added removed) do
      assert :processable = Webhook.classify("installation_repositories", action)
    end

    for action <-
          ~w(archived created deleted edited privatized publicized renamed transferred unarchived) do
      assert :processable = Webhook.classify("repository", action)
    end
  end

  test "marks known deferred repository and synchronization events pending" do
    pending_actions = %{
      "issues" =>
        ~w(assigned closed deleted edited labeled opened reopened transferred unassigned unlabeled),
      "issue_comment" => ~w(created edited deleted),
      "pull_request" =>
        ~w(assigned closed converted_to_draft edited labeled opened ready_for_review reopened synchronize unassigned unlabeled),
      "release" => ~w(created deleted edited prereleased published released unpublished)
    }

    for {event, actions} <- pending_actions, action <- actions do
      assert :pending_unsupported = Webhook.classify(event, action)
    end

    for event <- ~w(push create delete) do
      assert :pending_unsupported = Webhook.classify(event, nil)
    end
  end

  test "ignores unknown or structurally invalid event and action combinations" do
    ignored = [
      {"installation", "unknown"},
      {"installation", nil},
      {"installation_repositories", "created"},
      {"repository", "unknown"},
      {"issues", "unknown"},
      {"push", "created"},
      {"unknown", "created"},
      {String.duplicate("e", 65), "created"},
      {"repository", String.duplicate("a", 101)},
      {"repository\0suffix", "created"},
      {nil, nil},
      {:repository, :created}
    ]

    for {event, action} <- ignored do
      assert :ignored = Webhook.classify(event, action)
    end
  end

  test "signature and decoding errors do not contain secrets or payloads" do
    payload = "payload-that-must-not-be-returned"
    secret = "secret-that-must-not-be-returned"

    signature_result = Webhook.verify_signature(secret, payload, "sha256=invalid", 100)
    decode_result = Webhook.decode_payload(payload, 100)

    assert {:error, :invalid_signature} = signature_result
    assert {:error, :invalid_json} = decode_result

    rendered = inspect({signature_result, decode_result})
    refute rendered =~ secret
    refute rendered =~ payload
  end

  defp signature(secret, payload) do
    digest = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
    "sha256=" <> digest
  end
end
