defmodule Fornacast.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    :ok = prepare_boot()

    children = [
      Fornacast.Repo,
      {Phoenix.PubSub, name: Fornacast.PubSub}
    ]

    opts = [strategy: :one_for_one, name: Fornacast.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        heal_initialization()
        {:ok, pid}

      other ->
        other
    end
  end

  @doc """
  Runs pending migrations (when enabled) and ensures repository storage exists.

  Safe to call before the supervision tree starts: migration runs in
  `Ecto.Migrator.with_repo/2`'s own temporary repo, and directory creation is
  filesystem-only.
  """
  @spec prepare_boot() :: :ok
  def prepare_boot do
    maybe_migrate()
    _ = Fornacast.Storage.ensure_root!()
    :ok
  end

  @doc """
  Self-heals initialization state for installs that already have an admin but
  no `initialized_at` flag (pre-feature upgrades).

  Requires the supervised `Fornacast.Repo` to be running.
  """
  @spec heal_initialization() :: :ok
  def heal_initialization do
    # apply/3 keeps the compile-time umbrella graph clean: forge_accounts
    # depends on fornacast, not the reverse. At runtime ForgeAccounts is loaded.
    if not Fornacast.Setup.initialized?() and apply(ForgeAccounts, :admin_exists?, []) do
      Fornacast.Setup.mark_initialized!(%{id: nil})
    end

    :ok
  end

  defp maybe_migrate do
    if Application.get_env(:fornacast, :auto_migrate, true) do
      for repo <- Application.fetch_env!(:fornacast, :ecto_repos) do
        {:ok, _apps, _return} =
          Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
      end
    end

    :ok
  rescue
    error ->
      Logger.error("Boot migration failed: #{Exception.message(error)}")
      reraise error, __STACKTRACE__
  end
end
