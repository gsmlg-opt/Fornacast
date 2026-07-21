defmodule FornacastAPI.ErrorJSON do
  alias FornacastAPI.Error

  @documentation_url "https://docs.github.com/en/enterprise-server@3.21/rest/using-the-rest-api/getting-started-with-the-rest-api"

  def render(_template, _assigns) do
    error = Error.from_domain(:unclassified, @documentation_url)
    %{message: error.message, documentation_url: error.documentation_url}
  end
end
