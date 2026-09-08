defmodule Fornacast.Repo.Migrations.AddPullResourceProofs do
  use Ecto.Migration

  def change do
    alter table(:mirror_resource_states) do
      add(:provider_identity, :map)
      add(:confirmed_merge_state, :map)
    end

    unless repo().__adapter__() == Ecto.Adapters.Turso do
      for field <- [:provider_identity, :confirmed_merge_state] do
        create(
          constraint(:mirror_resource_states, "mirror_resource_states_#{field}_check",
            check:
              "#{field} is null or (jsonb_typeof(#{field}) = 'object' and " <>
                "octet_length(#{field}::text) <= 16384)"
          )
        )
      end
    end
  end
end
