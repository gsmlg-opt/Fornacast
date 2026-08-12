defmodule FornacastAPI.IssueContract do
  alias FornacastAPI.Pagination

  def list_filters(params) when is_map(params) do
    with {:ok, pagination} <- Pagination.parse(params),
         {:ok, state} <- enum(params, "state", :open, ~w(open closed all)),
         {:ok, labels} <- parse_labels(Map.get(params, "labels")),
         {:ok, assignee} <- optional_string(params, "assignee"),
         {:ok, creator} <- optional_string(params, "creator"),
         {:ok, sort} <- enum(params, "sort", :created, ~w(created updated comments)),
         {:ok, direction} <- enum(params, "direction", :desc, ~w(asc desc)),
         {:ok, since} <- timestamp(params, "since") do
      {:ok,
       pagination ++
         [
           state: state,
           labels: labels,
           assignee: assignee,
           creator: creator,
           sort: sort,
           direction: direction,
           since: since
         ]}
    end
  end

  def comment_filters(params) when is_map(params) do
    with {:ok, pagination} <- Pagination.parse(params),
         {:ok, since} <- timestamp(params, "since") do
      {:ok, pagination ++ [since: since]}
    end
  end

  defp optional_string(params, field) do
    case Map.get(params, field) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:validation, [%{resource: "Issue", field: field, code: :invalid}]}}
    end
  end

  defp enum(params, field, default, values) do
    case Map.get(params, field) do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        if value in values,
          do: {:ok, String.to_existing_atom(value)},
          else: {:error, {:validation, [%{resource: "Issue", field: field, code: :invalid}]}}

      _ ->
        {:error, {:validation, [%{resource: "Issue", field: field, code: :invalid}]}}
    end
  end

  defp timestamp(params, field) do
    case Map.get(params, field) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, 0} -> {:ok, datetime}
          _ -> {:error, {:validation, [%{resource: "Issue", field: field, code: :invalid}]}}
        end

      _ ->
        {:error, {:validation, [%{resource: "Issue", field: field, code: :invalid}]}}
    end
  end

  defp parse_labels(nil), do: {:ok, []}

  defp parse_labels(value) when is_binary(value) do
    labels = value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    if length(labels) <= 100,
      do: {:ok, labels},
      else: {:error, {:validation, [%{resource: "Issue", field: "labels", code: :unprocessable}]}}
  end

  defp parse_labels(_value),
    do: {:error, {:validation, [%{resource: "Issue", field: "labels", code: :invalid}]}}
end
