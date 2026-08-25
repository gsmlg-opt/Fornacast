defmodule ForgeAccounts.GitHubProfileSafetyTest do
  use ExUnit.Case, async: true

  alias ForgeAccounts.GitHubProfileSafety

  @pat "totally-secret-token"

  test "rejects substantial profile values contained by a credential" do
    profiles = [
      %{login: "secret-token"},
      %{name: "secret-token"},
      %{avatar_url: "https://avatars.githubusercontent.com/u/1/secret-token"},
      %{profile_url: "https://github.com/octocat/secret-token"},
      %{html_url: "https://github.com/octocat/secret-token"}
    ]

    for profile <- profiles do
      assert {:error, :invalid_response} = GitHubProfileSafety.validate(profile, @pat)
    end
  end

  test "preserves short ordinary profile values" do
    assert :ok =
             GitHubProfileSafety.validate(
               %{
                 login: "secret",
                 name: "token",
                 avatar_url: "https://avatars.githubusercontent.com/u/1/secret",
                 profile_url: "https://github.com/token",
                 html_url: "https://github.com/secret"
               },
               @pat
             )
  end

  test "enforces provider and domain byte caps with UTF-8 and NUL safety" do
    exact_avatar = "https://avatars.githubusercontent.com/" <> String.duplicate("a", 2_010)
    exact_profile = "https://github.com/" <> String.duplicate("b", 2_029)

    assert byte_size(exact_avatar) == 2_048
    assert byte_size(exact_profile) == 2_048

    assert :ok =
             GitHubProfileSafety.validate(%{
               login: String.duplicate("l", 255),
               name: String.duplicate("n", 255),
               avatar_url: exact_avatar,
               profile_url: exact_profile,
               html_url: exact_profile
             })

    for profile <- [
          %{login: String.duplicate("l", 256)},
          %{name: String.duplicate("n", 256)},
          %{avatar_url: exact_avatar <> "x"},
          %{profile_url: exact_profile <> "x"},
          %{html_url: exact_profile <> "x"},
          %{login: "unsafe\0login"},
          %{name: <<255>>}
        ] do
      assert {:error, :invalid_response} = GitHubProfileSafety.validate(profile)
    end
  end
end
