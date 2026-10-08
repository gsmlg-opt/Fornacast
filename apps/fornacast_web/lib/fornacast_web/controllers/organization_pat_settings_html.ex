defmodule FornacastWeb.OrganizationPATSettingsHTML do
  use FornacastWeb, :html
  alias FornacastWeb.OrganizationSettingsComponents
  embed_templates "organization_pat_settings_html/*"
  def csrf_token, do: Plug.CSRFProtection.get_csrf_token()
  def base(organization), do: "/organizations/#{organization.username}/settings/github"

  def accounts(view),
    do: for(owner <- view.owners, account <- owner.accounts, do: {owner, account})

  def credential_status(nil), do: "No owner PAT selected"
  def credential_status(%{credential_present: false}), do: "Saved PAT missing"
  def credential_status(%{credential_status: :valid}), do: "Saved PAT verified"
  def credential_status(_), do: "Saved PAT invalid"
  def repository_rows(view), do: Map.get(view.config.inventory, "repositories", [])

  def selected?(config, id),
    do: config.repository_selection == "all" or id in config.selected_repository_ids

  attr :summary, :map, required: true

  def sync_report(assigns) do
    ~H"""
    <div
      :if={@summary != %{}}
      class="mt-4 grid gap-2"
      data-pat-sync-report
      data-pat-sync-poll={if(@summary["status"] in ["queued", "running"], do: "true", else: nil)}
    >
      <.dm_alert
        :if={@summary["error"] not in [nil, ""]}
        id="pat-sync-report-error"
        variant="error"
        role="alert"
      >
        Synchronization could not finish. {sync_failure_message(@summary["error"])}
      </.dm_alert>
      <p role="status" class="text-sm text-on-surface-variant">
        Repositories: {@summary["total"]}. Succeeded: {@summary["succeeded"]}. Failed: {@summary[
          "failed"
        ]}. Pending: {@summary["pending"]}.
      </p>
      <details :if={@summary["repositories"] != []}>
        <summary>Repository synchronization results</summary>
        <div class="mt-2 overflow-x-auto">
          <table class="table" aria-label="Repository synchronization results">
            <thead>
              <tr>
                <th>GitHub repository</th><th>Status</th><th>Details</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={repository <- @summary["repositories"]}>
                <th scope="row">{repository["source_full_name"]}</th>
                <td>{repository["status"]}</td>
                <td>
                  <span :if={repository["progress"] not in [nil, %{}]} class="block">
                    {sync_progress_message(repository["progress"])}
                  </span>
                  <span :if={
                    repository["status"] in ["failed", "pending"] and
                      repository["error"] not in [nil, ""]
                  }>
                    {sync_failure_message(repository["error"])}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </details>
    </div>
    """
  end

  defp sync_progress_message(%{"phase" => "release_assets"} = progress),
    do: "Release assets: #{progress["completed"]} / #{progress["total"]} downloaded."

  defp sync_progress_message(%{"phase" => "lfs_scan"} = progress),
    do: "LFS scan: #{progress["completed"]} / #{progress["total"]} discovered objects checked."

  defp sync_progress_message(%{"phase" => "metadata"} = progress),
    do: "Metadata: #{progress["completed"]} checkpoints saved."

  defp sync_progress_message(_), do: ""

  defp sync_failure_message("repository_conflict"),
    do: "Existing repository conflicts with this GitHub source."

  defp sync_failure_message("credential_unavailable"),
    do: "The saved owner PAT is unavailable. Verify or replace it before trying again."

  defp sync_failure_message(reason) when reason in ["configuration_changed", "stale"],
    do: "The GitHub source or PAT configuration changed. Start synchronization again."

  defp sync_failure_message("stale_repository"),
    do: "The local repository changed during synchronization. Refresh and try again."

  defp sync_failure_message("lost_lease"),
    do: "Synchronization was interrupted. Start synchronization again."

  defp sync_failure_message(reason)
       when reason in ["git_divergence", "tag_retarget", "stale_ref"],
       do: "Git references conflict with local changes. Local branches and tags were retained."

  defp sync_failure_message("paused"),
    do: "Synchronization is paused. Resume it before trying again."

  defp sync_failure_message("not_enabled"),
    do: "GitHub synchronization is disabled. Enable it before trying again."

  defp sync_failure_message("request_gate_busy"),
    do:
      "Waiting for another GitHub request using this PAT. Synchronization will retry automatically."

  defp sync_failure_message("response_too_large"),
    do: "The GitHub response exceeded the 200 MiB limit."

  defp sync_failure_message("scan_work_limit"),
    do: "Git object scanning reached its work limit. Synchronization will retry automatically."

  defp sync_failure_message("label_normalization_conflict"),
    do: "GitHub label metadata conflicts with an imported label."

  defp sync_failure_message("persistence_unavailable"),
    do: "Repository metadata could not be saved. Synchronization will retry automatically."

  defp sync_failure_message("corrupt_repository"),
    do: "Git object integrity verification failed."

  defp sync_failure_message(_), do: "Could not synchronize this repository."
end
