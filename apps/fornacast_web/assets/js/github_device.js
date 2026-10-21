const initGitHubDevicePolling = () => {
  document.querySelectorAll('[data-github-device-poll="true"]').forEach((report) => {
    if (report.dataset.pollingStarted) return;
    report.dataset.pollingStarted = "true";
    const status = report.querySelector("[data-github-device-status]");
    const csrf = document.querySelector('meta[name="csrf-token"]')?.content;
    const id = report.dataset.githubDeviceId;
    let interval = Math.max(Number(report.dataset.interval) || 5, 1);
    const deadline = performance.now() + Math.max(Number(report.dataset.expiresIn) || 0, 0) * 1000;
    let stopped = false;
    let timer;
    let request;
    const feedback = (message) => {
      if (status) status.textContent = message;
    };
    const stop = (message) => {
      stopped = true;
      window.clearTimeout(timer);
      if (message) feedback(message);
    };
    const schedule = () => {
      if (!stopped && report.isConnected) {
        timer = window.setTimeout(
          poll,
          Math.min(interval * 1000, Math.max(deadline - performance.now(), 0)),
        );
      }
    };
    const poll = async () => {
      if (stopped || !report.isConnected) return;
      if (performance.now() >= deadline) {
        stop("The GitHub authorization code expired. Start again for a new code.");
        return;
      }
      request = new AbortController();
      const timeout = window.setTimeout(() => request.abort(), 45_000);
      try {
        const response = await fetch(`/settings/github/device/${encodeURIComponent(id)}/poll`, {
          method: "POST",
          credentials: "same-origin",
          cache: "no-store",
          signal: request.signal,
          headers: { Accept: "application/json", "x-csrf-token": csrf },
        });
        if (stopped) return;
        if (response.status === 401 || response.redirected) {
          stop("Sign in again and start a new GitHub authorization.");
          return;
        }
        const result = await response.json();
        if (result.status === "complete" && response.ok) {
          stop("GitHub connected.");
          window.location.assign("/settings/github");
          return;
        }
        if (result.status === "failed") {
          stop(result.message || "GitHub authorization stopped. Start again to retry.");
          return;
        }
        if (!response.ok || result.status !== "pending")
          throw new Error("authorization_unavailable");
        interval = Math.max(interval, Number(result.interval) || interval);
        feedback("Waiting for GitHub authorization.");
      } catch {
        if (!stopped) feedback("Authorization updates interrupted; retrying.");
      } finally {
        window.clearTimeout(timeout);
        request = null;
      }
      schedule();
    };
    window.addEventListener(
      "pagehide",
      () => {
        stop();
        request?.abort();
      },
      { once: true },
    );
    window.addEventListener("pageshow", (event) => {
      if (event.persisted) window.location.reload();
    });
    if (!csrf || !id) {
      stop("Refresh this page to start GitHub authorization again.");
      return;
    }
    schedule();
  });
};

export { initGitHubDevicePolling };
