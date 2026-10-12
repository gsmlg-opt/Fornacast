defmodule Fornacast.Repo.Migrations.AddUserThemePreference do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:theme_preference, :string, null: false, default: "auto")
    end

    create(
      constraint(:users, :users_theme_preference_check,
        check: "theme_preference IN ('auto', 'sunshine', 'moonlight')"
      )
    )
  end
end
