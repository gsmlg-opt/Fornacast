defmodule ForgeReleases.SyncEvents do
  @moduledoc false

  alias Fornacast.DomainOutbox

  def release(multi, event_type, options \\ []) when is_list(options) do
    DomainOutbox.record_multi(multi, :outbox, fn %{release: release} ->
      %{
        event_id: Ecto.UUID.generate(),
        aggregate_type: "release",
        aggregate_id: to_string(release.id),
        event_type: event_type,
        origin: Keyword.get(options, :origin, :fornacast),
        causation_id: Keyword.get(options, :causation_id),
        correlation_id: Keyword.get(options, :correlation_id),
        payload: %{
          "repository_id" => release.repository_id,
          "release_id" => release.id,
          "tag_name" => release.tag_name,
          "sync_version" => release.sync_version,
          "deleted" => not is_nil(release.deleted_at)
        }
      }
    end)
  end
end
