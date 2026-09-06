defmodule ForgeGitHub.IssueSyncProjection do
  @moduledoc """
  Canonical issue and comment projections shared by bootstrap and live sync.

  Mutable relationship membership is represented by immutable GitHub IDs. Names,
  logins, and local identities are retained only as transport material for the
  side that must be updated.
  """

  @issue_scalar_fields ~w(title body state state_reason)

  @type observation :: %{
          required(:presence) => :present,
          required(:resource_kind) => :issue | :issue_comment,
          required(:snapshot) => map(),
          optional(:local_resource_id) => pos_integer(),
          optional(:local_resource_type) => String.t(),
          optional(:local_version) => pos_integer(),
          optional(:github_object_id) => pos_integer(),
          optional(:github_node_id) => String.t(),
          optional(:github_number) => pos_integer(),
          optional(:remote_updated_at) => DateTime.t(),
          optional(:label_catalog) => map(),
          optional(:assignee_catalog) => map(),
          optional(:author) => map()
        }

  @spec from_local(map(), map()) :: {:ok, observation()} | {:error, :invalid_projection}
  def from_local(
        %{
          resource_kind: :issue,
          local_resource_id: local_id,
          local_resource_type: local_type,
          local_version: local_version,
          fields: fields,
          label_ids: label_ids,
          assignee_refs: assignee_refs
        },
        %{labels: labels, assignees: assignees}
      ) do
    with true <- valid_id?(local_id) and valid_id?(local_version),
         true <- valid_local_type?(local_type, "ForgeIssues.Issue"),
         {:ok, scalars} <- issue_scalars(fields),
         {:ok, label_ids, label_catalog} <- local_labels(label_ids, labels),
         {:ok, assignee_ids, assignee_catalog} <- local_assignees(assignee_refs, assignees) do
      {:ok,
       %{
         presence: :present,
         resource_kind: :issue,
         local_resource_id: local_id,
         local_resource_type: "ForgeIssues.Issue",
         local_version: local_version,
         snapshot:
           scalars
           |> Map.put("label_github_ids", label_ids)
           |> Map.put("assignee_github_ids", assignee_ids),
         label_catalog: label_catalog,
         assignee_catalog: assignee_catalog
       }}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  def from_local(
        %{
          resource_kind: :issue_comment,
          local_resource_id: local_id,
          local_resource_type: local_type,
          local_version: local_version,
          fields: %{"body" => body}
        },
        _relationships
      ) do
    if valid_id?(local_id) and valid_id?(local_version) and
         valid_local_type?(local_type, "ForgeIssues.Comment") and valid_comment_body?(body) do
      {:ok,
       %{
         presence: :present,
         resource_kind: :issue_comment,
         local_resource_id: local_id,
         local_resource_type: "ForgeIssues.Comment",
         local_version: local_version,
         snapshot: %{"body" => body},
         label_catalog: %{},
         assignee_catalog: %{}
       }}
    else
      {:error, :invalid_projection}
    end
  end

  def from_local(_projection, _relationships), do: {:error, :invalid_projection}

  @spec from_remote_issue(map(), map(), String.t() | nil) ::
          {:ok, observation()} | {:error, :invalid_projection}
  def from_remote_issue(issue, relationships, correlation_id \\ nil)

  def from_remote_issue(
        %{
          "id" => id,
          "node_id" => node_id,
          "number" => number,
          "title" => title,
          "body" => body,
          "state" => state,
          "state_reason" => state_reason,
          "labels" => labels,
          "assignees" => assignees,
          "user" => author,
          "created_at" => created_at,
          "updated_at" => updated_at
        },
        relationships,
        correlation_id
      ) do
    with true <- valid_id?(id) and valid_id?(number),
         true <- valid_text?(node_id),
         {:ok, created_at} <- datetime(created_at),
         {:ok, updated_at} <- datetime(updated_at),
         {:ok, scalars} <-
           issue_scalars(%{
             "title" => title,
             "body" => strip_issue_body(body, correlation_id),
             "state" => state,
             "state_reason" => state_reason
           }),
         {:ok, label_ids, label_catalog} <- remote_labels(labels, relationships),
         {:ok, assignee_ids, assignee_catalog} <- remote_assignees(assignees, relationships) do
      {:ok,
       %{
         presence: :present,
         resource_kind: :issue,
         github_object_id: id,
         github_node_id: node_id,
         github_number: number,
         remote_created_at: created_at,
         remote_updated_at: updated_at,
         snapshot:
           scalars
           |> Map.put("label_github_ids", label_ids)
           |> Map.put("assignee_github_ids", assignee_ids),
         label_catalog: label_catalog,
         assignee_catalog: assignee_catalog,
         author: Map.get(relationships, :author),
         raw_author: author
       }}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  def from_remote_issue(_issue, _relationships, _correlation_id),
    do: {:error, :invalid_projection}

  @spec from_remote_comment(map(), map(), String.t() | nil) ::
          {:ok, observation()} | {:error, :invalid_projection}
  def from_remote_comment(comment, relationships, correlation_id \\ nil)

  def from_remote_comment(
        %{
          "id" => id,
          "node_id" => node_id,
          "issue_number" => issue_number,
          "body" => body,
          "user" => author,
          "created_at" => created_at,
          "updated_at" => updated_at
        },
        relationships,
        correlation_id
      ) do
    body = strip_body(body, correlation_id)

    with true <- valid_id?(id) and valid_id?(issue_number),
         true <- valid_text?(node_id) and valid_comment_body?(body),
         {:ok, created_at} <- datetime(created_at),
         {:ok, updated_at} <- datetime(updated_at) do
      {:ok,
       %{
         presence: :present,
         resource_kind: :issue_comment,
         github_object_id: id,
         github_node_id: node_id,
         github_number: issue_number,
         remote_created_at: created_at,
         remote_updated_at: updated_at,
         snapshot: %{"body" => body},
         label_catalog: %{},
         assignee_catalog: %{},
         author: Map.get(relationships, :author),
         raw_author: author
       }}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  def from_remote_comment(_comment, _relationships, _correlation_id),
    do: {:error, :invalid_projection}

  @spec remote_attrs(:issue | :issue_comment, map(), map(), map()) ::
          {:ok, map()} | {:error, :invalid_projection}
  def remote_attrs(:issue, snapshot, label_catalog, assignee_catalog) do
    with {:ok, scalars} <- issue_scalars(snapshot),
         {:ok, label_names} <- catalog_values(snapshot["label_github_ids"], label_catalog, :name),
         {:ok, assignee_logins} <-
           catalog_values(snapshot["assignee_github_ids"], assignee_catalog, :login) do
      {:ok,
       scalars
       |> Map.put("labels", label_names)
       |> Map.put("assignees", assignee_logins)}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  def remote_attrs(:issue_comment, %{"body" => body}, _labels, _assignees)
      when is_binary(body) and body != "",
      do: {:ok, %{"body" => body}}

  def remote_attrs(_kind, _snapshot, _labels, _assignees),
    do: {:error, :invalid_projection}

  @spec local_relationships(map(), map(), map()) ::
          {:ok, %{local_label_ids: [pos_integer()], assignee_refs: [map()]}}
          | {:error, :invalid_projection}
  def local_relationships(snapshot, label_catalog, assignee_catalog) do
    with {:ok, local_label_ids} <-
           catalog_values(snapshot["label_github_ids"], label_catalog, :local_label_id),
         {:ok, assignee_refs} <-
           catalog_values(snapshot["assignee_github_ids"], assignee_catalog, :ref),
         true <- Enum.all?(local_label_ids, &valid_id?/1),
         true <- Enum.all?(assignee_refs, &valid_assignee_ref?/1) do
      {:ok, %{local_label_ids: local_label_ids, assignee_refs: assignee_refs}}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp issue_scalars(fields) when is_map(fields) do
    selected = Map.take(fields, @issue_scalar_fields)
    body = normalize_issue_body(selected["body"])

    if map_size(selected) == length(@issue_scalar_fields) and valid_title?(selected["title"]) and
         valid_issue_body?(body) and selected["state"] in ["open", "closed"] and
         representable_state_reason?(selected["state"], selected["state_reason"]) do
      {:ok, Map.put(selected, "body", body)}
    else
      {:error, :invalid_projection}
    end
  end

  defp issue_scalars(_fields), do: {:error, :invalid_projection}

  defp local_labels(label_ids, labels) when is_list(label_ids) and is_list(labels) do
    with true <- length(label_ids) == length(Enum.uniq(label_ids)),
         true <- Enum.all?(label_ids, &valid_id?/1),
         {:ok, catalog} <-
           catalog(labels, :github_object_id, fn label ->
             with true <- valid_id?(label[:local_label_id]),
                  true <- label[:local_label_id] in label_ids,
                  true <- valid_text?(label[:name]) do
               {:ok, %{name: label[:name], local_label_id: label[:local_label_id]}}
             else
               _invalid -> :error
             end
           end),
         true <- map_size(catalog) == length(label_ids) do
      {:ok, catalog |> Map.keys() |> Enum.sort(), catalog}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp local_labels(_ids, _labels), do: {:error, :invalid_projection}

  defp local_assignees(refs, assignees) when is_list(refs) and is_list(assignees) do
    with true <- Enum.all?(refs, &valid_assignee_ref?/1),
         {:ok, catalog} <-
           catalog(assignees, :github_user_id, fn assignee ->
             with true <- valid_assignee_ref?(assignee[:ref]),
                  true <- assignee[:ref] in refs,
                  true <- valid_text?(assignee[:login]) do
               {:ok, %{login: assignee[:login], ref: assignee[:ref]}}
             else
               _invalid -> :error
             end
           end) do
      {:ok, catalog |> Map.keys() |> Enum.sort(), catalog}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp local_assignees(_refs, _assignees), do: {:error, :invalid_projection}

  defp remote_labels(labels, relationships) when is_list(labels) and is_map(relationships) do
    resolved = Map.get(relationships, :labels, [])

    with {:ok, catalog} <-
           catalog(resolved, :github_object_id, fn label ->
             with true <- valid_id?(label[:local_label_id]),
                  true <- valid_text?(label[:name]) do
               {:ok, %{name: label[:name], local_label_id: label[:local_label_id]}}
             else
               _invalid -> :error
             end
           end),
         ids when is_list(ids) <- provider_ids(labels),
         true <- ids == Enum.sort(Map.keys(catalog)) do
      {:ok, ids, catalog}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp remote_labels(_labels, _relationships), do: {:error, :invalid_projection}

  defp remote_assignees(assignees, relationships)
       when is_list(assignees) and is_map(relationships) do
    resolved = Map.get(relationships, :assignees, [])

    with {:ok, catalog} <-
           catalog(resolved, :github_user_id, fn assignee ->
             with true <- valid_assignee_ref?(assignee[:ref]),
                  true <- valid_text?(assignee[:login]) do
               {:ok, %{login: assignee[:login], ref: assignee[:ref]}}
             else
               _invalid -> :error
             end
           end),
         ids when is_list(ids) <- provider_ids(assignees),
         true <- ids == Enum.sort(Map.keys(catalog)) do
      {:ok, ids, catalog}
    else
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp remote_assignees(_assignees, _relationships), do: {:error, :invalid_projection}

  defp provider_ids(values) do
    ids = Enum.map(values, &Map.get(&1, "id"))

    if Enum.all?(ids, &valid_id?/1) and length(ids) == length(Enum.uniq(ids)),
      do: Enum.sort(ids),
      else: :error
  end

  defp catalog(values, identity_key, mapper) when is_list(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn value, {:ok, acc} ->
      identity = value[identity_key]

      with true <- valid_id?(identity),
           false <- Map.has_key?(acc, identity),
           {:ok, mapped} <- mapper.(value) do
        {:cont, {:ok, Map.put(acc, identity, mapped)}}
      else
        _invalid -> {:halt, {:error, :invalid_projection}}
      end
    end)
  end

  defp catalog(_values, _key, _mapper), do: {:error, :invalid_projection}

  defp catalog_values(ids, catalog, field) when is_list(ids) and is_map(catalog) do
    if ids == Enum.sort(Enum.uniq(ids)) and Enum.all?(ids, &valid_id?/1) do
      Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, values} ->
        case get_in(catalog, [id, field]) do
          nil -> {:halt, {:error, :invalid_projection}}
          value -> {:cont, {:ok, [value | values]}}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        error -> error
      end
    else
      {:error, :invalid_projection}
    end
  end

  defp catalog_values(_ids, _catalog, _field), do: {:error, :invalid_projection}

  defp strip_issue_body(body, correlation_id),
    do: body |> strip_body(correlation_id) |> normalize_issue_body()

  defp strip_body(body, nil), do: body

  defp strip_body(body, correlation_id),
    do: ForgeMirrors.CorrelationMarker.strip(body, correlation_id)

  defp normalize_issue_body(""), do: nil
  defp normalize_issue_body(body), do: body

  defp representable_state_reason?("open", reason), do: reason in [nil, "reopened"]

  defp representable_state_reason?("closed", reason),
    do: reason in [nil, "completed", "not_planned"]

  defp valid_title?(title), do: is_binary(title) and title != "" and String.valid?(title)
  defp valid_issue_body?(nil), do: true
  defp valid_issue_body?(body), do: is_binary(body) and String.valid?(body)

  defp valid_comment_body?(body),
    do: is_binary(body) and body != "" and String.valid?(body)

  defp valid_local_type?(actual, expected), do: actual in [expected, nil]

  defp valid_assignee_ref?(%{kind: kind, id: id})
       when kind in [:local_user, :github_identity],
       do: valid_id?(id)

  defp valid_assignee_ref?(_ref), do: false

  defp valid_id?(id), do: is_integer(id) and id in 1..9_223_372_036_854_775_807

  defp valid_text?(value),
    do:
      is_binary(value) and value != "" and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, DateTime.truncate(datetime, :second)}
      _invalid -> {:error, :invalid_projection}
    end
  end

  defp datetime(%DateTime{} = value), do: {:ok, DateTime.truncate(value, :second)}
  defp datetime(_value), do: {:error, :invalid_projection}
end
