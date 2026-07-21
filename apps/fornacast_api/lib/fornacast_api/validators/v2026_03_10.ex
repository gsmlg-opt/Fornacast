defmodule FornacastAPI.Validators.V2026_03_10 do
  @schemas %{
    create_organization: %{
      resource: "Organization",
      required: ["login", "admin"],
      fields: %{
        "login" => :string,
        "admin" => :string,
        "profile_name" => :nullable_string
      }
    },
    update_organization: %{
      resource: "Organization",
      required: [],
      fields: %{
        "name" => :nullable_string,
        "description" => :nullable_string
      }
    },
    create_repository: %{
      resource: "Repository",
      required: ["name"],
      fields: %{
        "name" => :string,
        "description" => :nullable_string,
        "private" => :boolean,
        "visibility" => :string,
        "default_branch" => :string,
        "has_issues" => :boolean,
        "auto_init" => :boolean,
        "allow_merge_commit" => :boolean,
        "has_projects" => :boolean,
        "has_wiki" => :boolean,
        "has_discussions" => :boolean,
        "allow_squash_merge" => :boolean,
        "allow_rebase_merge" => :boolean
      }
    },
    update_repository: %{
      resource: "Repository",
      required: [],
      fields: %{
        "name" => :string,
        "description" => :nullable_string,
        "private" => :boolean,
        "visibility" => :string,
        "default_branch" => :string,
        "has_issues" => :boolean,
        "allow_merge_commit" => :boolean,
        "has_projects" => :boolean,
        "has_wiki" => :boolean,
        "has_discussions" => :boolean,
        "allow_squash_merge" => :boolean,
        "allow_rebase_merge" => :boolean
      }
    }
  }

  @unsupported_feature_fields [
    "has_projects",
    "has_wiki",
    "has_discussions",
    "allow_squash_merge",
    "allow_rebase_merge"
  ]

  def validate(operation, body) when is_atom(operation) and is_map(body) do
    %{resource: resource, required: required, fields: fields} =
      Map.fetch!(@schemas, operation)

    fields = Map.new(fields, fn {field, type} -> {field, predicate(type)} end)

    with {:ok, validated} <-
           FornacastAPI.RequestValidator.validate_fields(body, resource, fields, required) do
      validate_repository_constraints(operation, validated, resource)
    end
  end

  defp predicate(:string), do: &is_binary/1
  defp predicate(:nullable_string), do: &(is_nil(&1) or is_binary(&1))
  defp predicate(:boolean), do: &is_boolean/1

  defp validate_repository_constraints(operation, body, resource)
       when operation in [:create_repository, :update_repository] do
    errors =
      visibility_errors(body, resource) ++
        private_visibility_errors(body, resource) ++
        unsupported_feature_errors(body, resource)

    if errors == [], do: {:ok, body}, else: {:error, {:validation, errors}}
  end

  defp validate_repository_constraints(_operation, body, _resource), do: {:ok, body}

  defp visibility_errors(%{"visibility" => visibility}, resource)
       when visibility not in ["public", "private"] do
    [error(resource, "visibility")]
  end

  defp visibility_errors(_body, _resource), do: []

  defp private_visibility_errors(
         %{"private" => true, "visibility" => "public"},
         resource
       ) do
    [error(resource, "visibility")]
  end

  defp private_visibility_errors(
         %{"private" => false, "visibility" => "private"},
         resource
       ) do
    [error(resource, "visibility")]
  end

  defp private_visibility_errors(_body, _resource), do: []

  defp unsupported_feature_errors(body, resource) do
    for field <- @unsupported_feature_fields,
        Map.get(body, field) == true,
        do: error(resource, field)
  end

  defp error(resource, field), do: %{resource: resource, field: field, code: :unprocessable}
end
