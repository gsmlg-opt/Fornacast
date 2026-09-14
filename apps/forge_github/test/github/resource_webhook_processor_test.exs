defmodule ForgeGitHub.ResourceWebhookProcessorTest do
  use ExUnit.Case, async: true

  alias ForgeGitHub.WebhookProcessor
  alias ForgeMirrors.MirrorWebhookDelivery

  test "issue and pull notifications retain only their own immutable identities" do
    for {event, field, kind} <- [
          {"issues", "issue", "issue"},
          {"pull_request", "pull_request", "pull"}
        ] do
      delivery = delivery(event, %{field => %{"id" => 42, "number" => 7, "body" => "stale"}})

      assert :ok =
               WebhookProcessor.process(delivery,
                 resource_schedule: fn ^delivery, hints ->
                   assert hints == %{
                            "resource_kind" => kind,
                            "github_object_id" => 42,
                            "github_number" => 7,
                            "issue_kind" => if(kind == "pull", do: "pull_request", else: "issue")
                          }

                   {:ok, {:scheduled, :operation}}
                 end
               )
    end
  end

  test "comment hints preserve comment and parent issue identities including pull conversations" do
    for pull? <- [false, true] do
      issue = %{"id" => 42, "number" => 7}
      issue = if pull?, do: Map.put(issue, "pull_request", %{"url" => "not-used"}), else: issue

      delivery =
        delivery("issue_comment", %{
          "issue" => issue,
          "comment" => %{"id" => 84, "body" => "stale"}
        })

      assert :ok =
               WebhookProcessor.process(delivery,
                 resource_schedule: fn ^delivery, hints ->
                   assert hints == %{
                            "resource_kind" => "issue_comment",
                            "github_object_id" => 84,
                            "github_number" => 7,
                            "github_issue_id" => 42,
                            "issue_kind" => if(pull?, do: "pull_request", else: "issue")
                          }

                   {:ok, :scheduled}
                 end
               )
    end
  end

  test "deferred scheduling preserves bootstrap buffering and dependency failure retries" do
    delivery = delivery("issues", %{"issue" => %{"id" => 42, "number" => 7}})

    assert :defer =
             WebhookProcessor.process(delivery,
               resource_schedule: fn _, _ -> {:ok, :deferred} end
             )

    assert {:retry, "resource_trigger_unavailable", 30} =
             WebhookProcessor.process(delivery,
               resource_schedule: fn _, _ -> {:error, :unavailable} end
             )
  end

  test "release notifications retain immutable release identity and exact tag while ignoring assets" do
    delivery =
      delivery("release", %{
        "release" => %{
          "id" => 84,
          "tag_name" => "release/v1.0",
          "body" => "stale",
          "assets" => [%{"id" => 99, "name" => "never-copied"}]
        }
      })

    assert :ok =
             WebhookProcessor.process(delivery,
               resource_schedule: fn ^delivery, hints ->
                 assert hints == %{
                          "resource_kind" => "release",
                          "github_object_id" => 84,
                          "tag_name" => "release/v1.0"
                        }

                 {:ok, {:scheduled, :operation}}
               end
             )
  end

  test "duplicate and out-of-order resource payloads schedule the same immutable canonical lookup" do
    for {event, resource, expected} <- [
          {"issues", %{"issue" => %{"id" => 42, "number" => 7}},
           %{
             "resource_kind" => "issue",
             "github_object_id" => 42,
             "github_number" => 7,
             "issue_kind" => "issue"
           }},
          {"issue_comment",
           %{"issue" => %{"id" => 42, "number" => 7}, "comment" => %{"id" => 84}},
           %{
             "resource_kind" => "issue_comment",
             "github_object_id" => 84,
             "github_number" => 7,
             "github_issue_id" => 42,
             "issue_kind" => "issue"
           }},
          {"pull_request", %{"pull_request" => %{"id" => 43, "number" => 7}},
           %{
             "resource_kind" => "pull",
             "github_object_id" => 43,
             "github_number" => 7,
             "issue_kind" => "pull_request"
           }},
          {"release", %{"release" => %{"id" => 44, "tag_name" => "v1.0.0"}},
           %{"resource_kind" => "release", "github_object_id" => 44, "tag_name" => "v1.0.0"}}
        ] do
      for body <- ["newer mutable payload", "older mutable payload"] do
        delivery = delivery(event, mutable_resource(resource, body))

        assert :ok =
                 WebhookProcessor.process(delivery,
                   resource_schedule: fn ^delivery, hints ->
                     assert hints == expected
                     refute Map.has_key?(hints, "body")
                     {:ok, :scheduled}
                   end
                 )
      end
    end
  end

  test "release notifications accept tags at the 255 Unicode codepoint boundary" do
    tag_name = String.duplicate("界", 255)
    delivery = delivery("release", %{"release" => %{"id" => 84, "tag_name" => tag_name}})

    assert :ok =
             WebhookProcessor.process(delivery,
               resource_schedule: fn ^delivery, hints ->
                 assert hints["tag_name"] == tag_name
                 {:ok, {:scheduled, :operation}}
               end
             )
  end

  test "wiki notifications and release-asset identities never enter metadata scheduling" do
    wiki = delivery("gollum", %{"pages" => [%{"page_name" => "Home"}]})

    assert :ignore =
             WebhookProcessor.process(wiki,
               resource_schedule: fn _, _ -> flunk("wiki content was scheduled") end
             )

    release =
      delivery("release", %{
        "release" => %{
          "id" => 84,
          "tag_name" => "v1",
          "assets" => [%{"id" => 99, "name" => "artifact.tgz"}]
        }
      })

    assert :ok =
             WebhookProcessor.process(release,
               resource_schedule: fn _, hints ->
                 refute Map.has_key?(hints, "assets")
                 refute Map.has_key?(hints, "asset_ids")
                 {:ok, :scheduled}
               end
             )
  end

  test "malformed or confused provider identities are not scheduled" do
    for issue <- [
          %{"id" => 0, "number" => 7},
          %{"id" => 42, "number" => "7"},
          %{"id" => 42, "number" => 7, "pull_request" => %{}}
        ] do
      assert {:fail, "invalid_webhook_payload"} =
               WebhookProcessor.process(delivery("issues", %{"issue" => issue}),
                 resource_schedule: fn _, _ -> flunk("invalid identity scheduled") end
               )
    end
  end

  defp delivery(event, resource) do
    payload =
      Map.merge(resource, %{
        "action" => "edited",
        "installation" => %{"id" => 1},
        "repository" => %{"id" => 2}
      })

    %MirrorWebhookDelivery{
      id: 1,
      delivery_guid: Ecto.UUID.generate(),
      event: event,
      action: "edited",
      installation_id: 1,
      github_repository_id: 2,
      raw_payload: JSON.encode!(payload)
    }
  end

  defp mutable_resource(%{"comment" => comment} = resource, body),
    do: %{resource | "comment" => Map.put(comment, "body", body)}

  defp mutable_resource(%{"issue" => issue} = resource, body),
    do: %{resource | "issue" => Map.put(issue, "body", body)}

  defp mutable_resource(%{"pull_request" => pull} = resource, body),
    do: %{resource | "pull_request" => Map.put(pull, "body", body)}

  defp mutable_resource(%{"release" => release} = resource, body),
    do: %{resource | "release" => Map.put(release, "body", body)}
end
