defmodule FornacastWeb.AdminJobsHTML do
  @moduledoc false

  use FornacastWeb, :html

  embed_templates "admin_jobs_html/*"

  defp jobs_path(filters, page) do
    query =
      [{"queue", filters.queue}, {"state", filters.state}, {"page", page}]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> URI.encode_query()

    "/-/admin/jobs?" <> query
  end

  defp timestamp(nil), do: "—"
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value) <> "Z"

  defp state_options do
    Enum.map(Styx.Job.states(), fn state ->
      value = Atom.to_string(state)
      {value, String.capitalize(value)}
    end)
  end
end
