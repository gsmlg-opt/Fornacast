defmodule ForgeIssues do
  @moduledoc """
  Composable operations for canonical issue identities.

  Callers build one complete `Ecto.Multi` and execute it through `transaction/1`.
  Authorization remains the responsibility of the outer issue or pull-request
  context, where repository access is available.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias ForgeIssues.{Issue, NumberSequence}
  alias Fornacast.Repo

  @turso_busy_attempts 12
  @turso_busy_backoff_ms 5

  @doc """
  Executes a complete caller-owned multi as one transaction.

  ExTurso classifies concurrent-writer contention as a retryable `:busy`
  exception. On Turso, this function retries the entire transaction a bounded
  number of times; other adapters and all other errors are executed once.
  Multi callbacks must therefore keep external side effects outside the
  transaction boundary.
  """
  @spec transaction(Multi.t()) ::
          {:ok, map()} | {:error, Multi.name(), term(), map()}
  def transaction(%Multi{} = multi) do
    attempts = if Repo.__adapter__() == Ecto.Adapters.Turso, do: @turso_busy_attempts, else: 1
    transact(multi, attempts)
  end

  @spec insert_numbered_identity(
          Multi.t(),
          Multi.name(),
          ForgeRepos.Repository.t(),
          ForgeAccounts.User.t(),
          :issue | :pull_request,
          map()
        ) :: Multi.t()
  def insert_numbered_identity(multi, key, repository, actor, kind, attrs)
      when kind in [:issue, :pull_request] do
    sequence_key = {key, :sequence}
    number_key = {key, :number}

    multi
    |> Multi.insert(
      sequence_key,
      NumberSequence.changeset(%NumberSequence{}, %{repository_id: repository.id}),
      on_conflict: :nothing,
      conflict_target: [:repository_id]
    )
    |> Multi.run(number_key, fn repo, _changes ->
      query = from(sequence in NumberSequence, where: sequence.repository_id == ^repository.id)

      case repo.update_all(query, inc: [next_number: 1]) do
        {1, _rows} ->
          next_number = repo.one!(from(sequence in query, select: sequence.next_number))
          {:ok, next_number - 1}

        {0, _rows} ->
          {:error, {:unavailable, :database}}
      end
    end)
    |> Multi.insert(key, fn changes ->
      %Issue{
        repository_id: repository.id,
        number: Map.fetch!(changes, number_key),
        kind: kind,
        author_user_id: actor.id
      }
      |> Issue.create_changeset(attrs)
    end)
  end

  @spec update_identity(Multi.t(), Multi.name(), Issue.t(), ForgeAccounts.User.t(), map()) ::
          Multi.t()
  def update_identity(multi, key, %Issue{} = issue, _actor, attrs) do
    Multi.update(multi, key, fn _changes -> Issue.update_changeset(issue, attrs) end)
  end

  defp transact(multi, attempts_remaining) do
    Repo.transaction(multi)
  rescue
    error in Turso.Error ->
      if Repo.__adapter__() == Ecto.Adapters.Turso and error.code == :busy and
           attempts_remaining > 1 do
        attempt = @turso_busy_attempts - attempts_remaining + 1
        Process.sleep(attempt * @turso_busy_backoff_ms)
        transact(multi, attempts_remaining - 1)
      else
        reraise error, __STACKTRACE__
      end
  end
end
