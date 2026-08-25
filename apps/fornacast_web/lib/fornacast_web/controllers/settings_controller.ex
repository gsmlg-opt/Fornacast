defmodule FornacastWeb.SettingsController do
  use FornacastWeb, :controller

  def index(%Plug.Conn{assigns: %{current_user: user}} = conn, _params) do
    profile = """
    #{section_header("Profile", "Review the identity attached to your Fornacast account.", "")}
    <section class="settings-profile-panel" aria-labelledby="profile-details-heading">
      <h2 id="profile-details-heading">Profile details</h2>
      <dl class="settings-profile-list">
        <div class="settings-profile-row">
          <dt>Username</dt>
          <dd>@#{escape(user.username)}</dd>
        </div>
        <div class="settings-profile-row">
          <dt>Email</dt>
          <dd>#{escape(user.email)}</dd>
        </div>
      </dl>
    </section>
    """

    page(conn, "Settings", settings_layout(:profile, profile))
  end
end
