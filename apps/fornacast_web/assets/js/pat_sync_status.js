const initPatSyncStatusPolling = () => {
  let report = document.querySelector('[data-pat-sync-poll="true"]');
  if (!report) return;

  const poll = async () => {
    if (!report.isConnected || report.dataset.patSyncPoll !== "true") return;

    try {
      const response = await fetch(window.location.href, {
        credentials: "same-origin",
        headers: { Accept: "text/html" },
      });
      if (response.ok && !response.redirected) {
        const page = new DOMParser().parseFromString(await response.text(), "text/html");
        const next = page.querySelector("[data-pat-sync-report]");
        if (next) {
          const details = next.querySelector("details");
          if (details) details.open = report.querySelector("details")?.open === true;
          report.replaceWith(next);
          report = next;
        }
      }
    } catch {
      // Keep the last saved progress visible while the connection recovers.
    }

    if (report.isConnected && report.dataset.patSyncPoll === "true") {
      window.setTimeout(poll, 5_000);
    }
  };

  window.setTimeout(poll, 5_000);
};

export { initPatSyncStatusPolling };
