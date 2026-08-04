defmodule ForgeIssues do
  import Ecto.Query

  alias Ecto.{Changeset, Multi}
  alias ForgeIssues.{Issue, NumberSequence}

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
  def update_identity(multi, key, %Issue{} = issue, actor, attrs) do
    Multi.update(multi, key, fn _changes ->
      case authorize_identity_update(issue, actor) do
        :ok ->
          Issue.update_changeset(issue, attrs)

        {:error, reason} ->
          Changeset.add_error(Issue.update_changeset(issue, %{}), :actor, Atom.to_string(reason))
      end
    end)
  end

  defp authorize_identity_update(%Issue{author_user_id: author_user_id}, %{id: actor_id})
       when actor_id == author_user_id,
       do: :ok

  defp authorize_identity_update(%Issue{}, _actor), do: {:error, :forbidden}
end
