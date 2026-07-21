defmodule FornacastAPI.RequestValidator do
  @versions %{
    "2022-11-28" => FornacastAPI.Validators.V2022_11_28,
    "2026-03-10" => FornacastAPI.Validators.V2026_03_10
  }

  def validate(version, operation, body) when is_atom(operation) and is_map(body) do
    Map.fetch!(@versions, version).validate(operation, body)
  end

  def validate_fields(body, resource, fields, required) do
    unknown = Map.keys(body) -- Map.keys(fields)
    missing = Enum.reject(required, &Map.has_key?(body, &1))

    errors =
      Enum.map(missing, &error(resource, &1, :missing_field)) ++
        Enum.map(unknown, &error(resource, &1, :unprocessable)) ++
        type_errors(body, resource, fields)

    if errors == [], do: {:ok, body}, else: {:error, {:validation, errors}}
  end

  defp type_errors(body, resource, fields) do
    for {field, predicate} <- fields,
        Map.has_key?(body, field),
        not predicate.(Map.fetch!(body, field)),
        do: error(resource, field, :invalid)
  end

  defp error(resource, field, code), do: %{resource: resource, field: field, code: code}
end
