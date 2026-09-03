const POLLABLE_SELECTOR = "[data-import-status-url]";
const MIN_INTERVAL_MS = 2_000;
const MAX_INTERVAL_MS = 30_000;

const parseStatusUrl = (element) => {
  const url = element.dataset.importStatusUrl;

  if (typeof url !== "string" || url === "" || !url.startsWith("/imports/")) {
    return null;
  }

  return url;
};

const formatCount = (value) => {
  if (typeof value === "number" && Number.isFinite(value)) {
    return String(value);
  }

  return "0";
};

const updateText = (root, selector, value) => {
  root.querySelectorAll(selector).forEach((node) => {
    node.textContent = value;
  });
};

const updateBadge = (root, state) => {
  root.querySelectorAll("[data-import-state-label]").forEach((node) => {
    node.textContent = state.replaceAll("_", " ");
  });
};

const updateCounts = (root, counts) => {
  if (!counts || typeof counts !== "object") {
    return;
  }

  updateText(root, "[data-import-count-selected]", formatCount(counts.selected));
  updateText(root, "[data-import-count-published]", formatCount(counts.published));
  updateText(root, "[data-import-count-skipped]", formatCount(counts.skipped));
  updateText(root, "[data-import-count-warnings]", formatCount(counts.warnings));
  updateText(root, "[data-import-count-failures]", formatCount(counts.failures));
};

const updateRepositories = (root, repositories) => {
  if (!Array.isArray(repositories)) {
    return;
  }

  repositories.forEach((repository) => {
    const row = root.querySelector(`[data-repository-item="${repository.id}"]`);

    if (!row) {
      return;
    }

    const stateNode = row.querySelector("[data-repository-state]");
    const waitNode = row.querySelector("[data-repository-wait]");
    const linkNode = row.querySelector("[data-repository-published-link]");

    if (stateNode && typeof repository.state === "string") {
      stateNode.textContent = repository.state.replaceAll("_", " ");
    }

    if (waitNode) {
      if (typeof repository.wait_reason === "string" && repository.wait_reason !== "") {
        waitNode.textContent = repository.wait_reason.replaceAll("_", " ");
        waitNode.hidden = false;
      } else if (typeof repository.next_attempt_at === "string") {
        waitNode.textContent = `Resume after ${repository.next_attempt_at}`;
        waitNode.hidden = false;
      } else {
        waitNode.textContent = "None";
        waitNode.hidden = false;
      }
    }

    if (linkNode instanceof HTMLAnchorElement) {
      if (typeof repository.published_href === "string" && repository.published_href !== "") {
        linkNode.href = repository.published_href;
        linkNode.hidden = false;
      } else {
        linkNode.hidden = true;
      }
    }
  });
};

const applyStatus = (root, payload) => {
  if (!payload || typeof payload !== "object") {
    return false;
  }

  if (typeof payload.state === "string") {
    updateBadge(root, payload.state);
  }

  updateCounts(root, payload.counts);
  updateRepositories(root, payload.repositories);

  if (typeof payload.next_attempt_at === "string" && payload.next_attempt_at !== "") {
    updateText(root, "[data-import-next-attempt]", payload.next_attempt_at);
  }

  if (typeof payload.wait_reason === "string" && payload.wait_reason !== "") {
    updateText(root, "[data-import-wait-reason]", payload.wait_reason.replaceAll("_", " "));
  }

  return payload.poll !== false && payload.terminal !== true;
};

const pollOnce = async (root, url) => {
  const response = await fetch(url, {
    credentials: "same-origin",
    headers: { Accept: "application/json" },
  });

  if (!response.ok) {
    throw new Error(`status ${response.status}`);
  }

  return response.json();
};

const schedulePoll = (root, url, intervalMs) => {
  const timer = window.setTimeout(async () => {
    let nextInterval = Math.min(intervalMs * 2, MAX_INTERVAL_MS);

    try {
      const payload = await pollOnce(root, url);

      if (applyStatus(root, payload)) {
        schedulePoll(root, url, MIN_INTERVAL_MS);
      }
    } catch {
      schedulePoll(root, url, nextInterval);
    }
  }, intervalMs);

  root.dataset.importStatusTimer = String(timer);
};

const initImportStatusPolling = () => {
  document.querySelectorAll(POLLABLE_SELECTOR).forEach((root) => {
    const url = parseStatusUrl(root);

    if (!url || root.dataset.importStatusInitialized === "true") {
      return;
    }

    root.dataset.importStatusInitialized = "true";
    schedulePoll(root, url, MIN_INTERVAL_MS);
  });
};

export { initImportStatusPolling };
