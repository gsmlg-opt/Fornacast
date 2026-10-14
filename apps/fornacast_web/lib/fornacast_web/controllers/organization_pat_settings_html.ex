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

  def run_path(organization, run), do: base(organization) <> "/runs/#{run["id"]}"

  def task_status(%{"status" => "failed", "succeeded" => count}) when count > 0,
    do: "failed (partial success)"

  def task_status(%{"status" => "succeeded", "warnings" => count}) when count > 0,
    do: "succeeded with warnings"

  def task_status(run), do: run["status"]

  attr :organization, :map, required: true
  attr :run, :map, required: true

  def task_report(assigns) do
    ~H"""
    <section
      class="grid gap-3"
      data-pat-sync-report
      data-pat-sync-poll={if @run["terminal"], do: "false", else: "true"}
      data-pat-sync-status-url={run_path(@organization, @run) <> "/status"}
      data-pat-sync-updated-at={@run["updated_at"]}
    >
      <h3 class="text-xl font-semibold">Synchronization #{@run["id"]}: {task_status(@run)}</h3>
      <p role="status">
        Phase: {@run["phase"]}. Repositories: {@run["total"]}. Succeeded: {@run["succeeded"]}. Failed: {@run[
          "failed"
        ]}. Pending: {@run["pending"]}. Warnings: {@run["warnings"]}.
      </p>
      <p class="text-sm text-on-surface-variant">
        Requested: {@run["requested_at"]}. Started: {@run["started_at"] || "Not started"}. Last recorded activity: {@run[
          "updated_at"
        ]}. Finished: {@run["finished_at"] || "Not finished"}.
      </p>
      <p class="text-sm text-on-surface-variant">
        Worker heartbeat: {@run["heartbeat_at"] || "Not started"}. Last progress: {@run[
          "last_progress_at"
        ] || "No progress recorded"}.
      </p>
      <p :if={@run["execution_state"]} class="text-sm">
        Latest worker delivery: {@run["execution_state"]}. Delivery attempts: {@run["attempts"]} / {@run[
          "max_attempts"
        ]}. Last worker start: {@run["worker_started_at"] || "Not started"}.
      </p>
      <p class="text-sm" data-pat-sync-poll-feedback role="status">
        Status checked: {@run["observed_at"]}.
      </p>
      <.dm_alert :if={@run["error"]} id="pat-sync-report-error" variant="error" role="alert">
        Synchronization could not finish. {sync_failure_message(@run["error"])} ({@run["error"]})
      </.dm_alert>
      <p :if={@run["wait_reason"]}>Waiting: {@run["wait_reason"]}.</p>
      <p :if={@run["next_attempt_at"]}>Next attempt: {@run["next_attempt_at"]}.</p>
      <p :if={@run["terminal"] and @run["pending"] > 0}>
        The task ended with {@run["pending"]} unfinished repositories. Completed repositories were retained.
      </p>
      <p :if={@run["total"] == 0 and !@run["terminal"]}>
        Waiting for repository discovery. The task has been accepted.
      </p>
      <details :if={@run["repositories"] != []} open>
        <summary>Repository synchronization results</summary>
        <div class="mt-2 overflow-x-auto">
          <table class="table" aria-label="Repository synchronization results">
            <thead>
              <tr>
                <th>GitHub repository</th><th>Status / phase</th><th>Details</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={repository <- @run["repositories"]}>
                <th scope="row">{repository["source_full_name"]}</th>
                <td>{repository["status"]} / {repository["phase"] || repository["mode"]}</td>
                <td>
                  <span class="block">{sync_progress_message(repository["progress"])}</span>
                  <span :if={repository["error"]} class="block">{sync_failure_message(
                    repository["error"]
                  )} ({repository["error"]})</span>
                  <span :if={repository["wait_reason"]} class="block">Waiting: {repository[
                    "wait_reason"
                  ]}.</span>
                  <span :if={repository["next_attempt_at"]} class="block">Next attempt: {repository[
                    "next_attempt_at"
                  ]}.</span>
                  <span :if={repository["execution_state"]} class="block">Latest worker delivery: {repository[
                    "execution_state"
                  ]}.</span>
                  <span class="block">Delivery attempts: {repository["attempts"] || "Unavailable"} / {repository[
                    "max_attempts"
                  ] || "Unavailable"}. Import attempts: {repository["import_attempts"]}. Warnings: {repository[
                    "warnings"
                  ]}.</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </details>
      <div class="flex gap-3" data-pat-sync-actions>
        <.dm_link href={run_path(@organization, @run)} class="text-primary">View task #{@run["id"]}</.dm_link>
        <.dm_link href={base(@organization) <> "/runs"} class="text-primary">Synchronization history</.dm_link>
        <.dm_link :if={@run["terminal"]} href={base(@organization)} class="text-primary">Open configuration to synchronize again</.dm_link>
        <span :if={!@run["terminal"]}>Synchronization is active.</span>
      </div>
    </section>
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

  defp sync_failure_message(reason) when reason in ["invalid_pagination", "invalid_response"],
    do: "GitHub returned data that could not be processed."

  defp sync_failure_message(reason) when reason in ["retry_exhausted", "job_discarded"],
    do: "The task exhausted its retry budget."

  defp sync_failure_message(_), do: "Could not synchronize this repository."
end
