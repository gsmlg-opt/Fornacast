defmodule FornacastAPI.GitHubWebhookController do
  use FornacastAPI, :controller

  alias FornacastAPI.Response

  def create(%Plug.Conn{assigns: %{github_webhook: webhook}} = conn, _params) do
    inbox = Application.get_env(:fornacast_api, :github_webhook_inbox, ForgeMirrors)

    attrs = %{
      delivery_guid: webhook.delivery_guid,
      hook_id: webhook.hook_id,
      event: webhook.event,
      action: webhook.action,
      installation_id: webhook.installation_id,
      github_repository_id: webhook.github_repository_id,
      signature_version: "sha256",
      raw_payload: webhook.raw_body
    }

    state = inbox_state(webhook.classification)

    case inbox.enqueue_webhook_delivery(attrs, state) do
      {:ok, _delivery, status} when status in [:enqueued, :duplicate] ->
        Response.json(conn, 202, %{status: "accepted"})

      {:error, :delivery_collision} ->
        Response.json(conn, 409, %{message: "Conflict"})

      {:error, reason} when reason in [:unavailable, :invalid_argument] ->
        Response.json(conn, 503, %{message: "Service Unavailable"})

      {:error, %Ecto.Changeset{}} ->
        Response.json(conn, 400, %{message: "Bad Request"})

      {:error, _safe_reason} ->
        Response.json(conn, 503, %{message: "Service Unavailable"})
    end
  rescue
    _exception -> Response.json(conn, 503, %{message: "Service Unavailable"})
  catch
    _kind, _reason -> Response.json(conn, 503, %{message: "Service Unavailable"})
  end

  defp inbox_state(:processable), do: :pending
  defp inbox_state(:pending_unsupported), do: :pending_unsupported
  defp inbox_state(:ignored), do: :ignored
end
