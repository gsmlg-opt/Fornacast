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
end
