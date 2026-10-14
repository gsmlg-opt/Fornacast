const initPatSyncStatusPolling = () => {
  document.querySelectorAll('[data-pat-sync-poll="true"]').forEach((initialReport) => {
    let report = initialReport;
    let lastChecked = null;
    const feedback = (state, message) => {
      report.dataset.patSyncConnection = state;
      const element = report.querySelector("[data-pat-sync-poll-feedback]");
      if (element) {
        element.textContent = `${message} Last successful check: ${lastChecked || "not checked in this page"}. Last recorded activity: ${report.dataset.patSyncUpdatedAt || "unknown"}.`;
      }
    };
    const poll = async () => {
      if (!report.isConnected || report.dataset.patSyncPoll !== "true") return;
      const url = report.dataset.patSyncStatusUrl;
      if (!url) {
        feedback("error", "Status updates unavailable: missing task status address.");
        return;
      }
      const controller = new AbortController();
      const timeout = window.setTimeout(() => controller.abort(), 15_000);
      try {
        const response = await fetch(url, {
          credentials: "same-origin",
          cache: "no-store",
          signal: controller.signal,
          headers: { Accept: "application/json" },
        });
        if (response.status === 401 || response.redirected) {
          feedback("login", "Status updates stopped. Sign in again and refresh this page.");
          return;
        }
        if (response.status === 404 || response.status === 403) {
          feedback(
            "unavailable",
            "Status updates stopped. This task is unavailable or access has changed.",
          );
          return;
        }
        if (!response.ok) throw new Error("status_unavailable");
        const status = await response.json();
        const page = new DOMParser().parseFromString(status.html, "text/html");
        const next = page.querySelector("[data-pat-sync-report]");
        if (!next || !status.run) throw new Error("invalid_status");
        const details = next.querySelector("details");
        const oldDetails = report.querySelector("details");
        if (details && oldDetails) details.open = oldDetails.open;
        report.replaceWith(next);
        report = next;
        lastChecked = status.run.observed_at;
        feedback("connected", status.run.terminal ? "Task finished." : "Status updates connected.");
      } catch {
        feedback(
          "stale",
          "Status updates interrupted; retrying. The displayed result may be stale.",
        );
      } finally {
        window.clearTimeout(timeout);
      }
      if (report.isConnected && report.dataset.patSyncPoll === "true") {
        window.setTimeout(poll, 5_000);
      }
    };
    // Poll immediately even when discovery has not produced any repository rows.
    poll();
  });
};

export { initPatSyncStatusPolling };
