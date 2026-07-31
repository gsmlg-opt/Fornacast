defmodule FornacastAPI.GraphQL.Schema do
  @moduledoc false
  use Absinthe.Schema

  alias FornacastAPI.GraphQL.Resolvers

  query do
    @desc "The authenticated user."
    field :viewer, :user do
      resolve(&Resolvers.viewer/3)
    end

    @desc "Lookup a user by login."
    field :user, :user do
      arg(:login, non_null(:string))
      resolve(&Resolvers.user/3)
    end

    @desc "Lookup an organization by login."
    field :organization, :organization do
      arg(:login, non_null(:string))
      resolve(&Resolvers.organization/3)
    end

    @desc "Lookup a repository by owner login and name."
    field :repository, :repository do
      arg(:owner, non_null(:string))
      arg(:name, non_null(:string))
      resolve(&Resolvers.repository/3)
    end
  end

  object :user do
    field :id, non_null(:id)
    field :database_id, :integer
    field :login, non_null(:string)
    field :name, :string
    field :url, non_null(:string)
    field :email, :string
    field :bio, :string
    field :is_site_admin, non_null(:boolean)
  end

  object :organization do
    field :id, non_null(:id)
    field :database_id, :integer
    field :login, non_null(:string)
    field :name, :string
    field :description, :string
    field :url, non_null(:string)
  end

  object :repository do
    field :id, non_null(:id)
    field :database_id, :integer
    field :name, non_null(:string)
    field :name_with_owner, non_null(:string)
    field :description, :string
    field :url, non_null(:string)
    field :is_private, non_null(:boolean)
  end
end
