/**
 * Clipboard behavior for Fornacast Git components.
 * Adapted from Phoenix Duskmoon UI 9.16.7; see THIRD_PARTY_NOTICES.md.
 */

const COPY_SELECTOR = "[data-fc-copy-value]";
const COPY_FEEDBACK_DURATION = 2000;
const COPY_LISTENER = Symbol.for("fornacast-component.copy-listener");
const copyFeedback = new WeakMap();

export async function copyTextToClipboard(value, environment = globalThis) {
  const clipboard = environment.navigator?.clipboard;

  if (typeof clipboard?.writeText === "function") {
    await clipboard.writeText(value);
    return;
  }

  const document = environment.document;

  if (!document?.body || typeof document.execCommand !== "function") {
    throw new Error("Clipboard API is unavailable");
  }

  const textArea = document.createElement("textarea");
  const activeElement = document.activeElement;
  textArea.value = value;
  textArea.setAttribute("readonly", "");
  textArea.style.position = "fixed";
  textArea.style.opacity = "0";
  document.body.appendChild(textArea);

  try {
    textArea.focus();
    textArea.select();

    if (!document.execCommand("copy")) {
      throw new Error("Clipboard copy command failed");
    }
  } finally {
    document.body.removeChild(textArea);
    activeElement?.focus?.();
  }
}

function copyStatus(button) {
  const sibling = button.nextElementSibling;

  if (sibling?.matches?.("[data-fc-copy-status]")) {
    return sibling;
  }

  return button.parentElement?.querySelector?.("[data-fc-copy-status]") ?? null;
}

function showCopyFeedback(button, message, state, options) {
  const label = button.querySelector?.("[data-fc-copy-label]");
  const status = copyStatus(button);
  const previous = copyFeedback.get(button);
  const cancelReset = options.cancelReset ?? globalThis.clearTimeout;
  const scheduleReset = options.scheduleReset ?? globalThis.setTimeout;

  if (previous?.timer !== undefined) {
    cancelReset(previous.timer);
  }

  const originalLabel = previous?.originalLabel ?? label?.textContent ?? "Copy";

  if (label) label.textContent = message;
  if (status) status.textContent = message;
  button.dataset.fcCopyState = state;

  const timer = scheduleReset(() => {
    if (label) label.textContent = originalLabel;
    if (status) status.textContent = "";
    delete button.dataset.fcCopyState;
    copyFeedback.delete(button);
  }, COPY_FEEDBACK_DURATION);

  copyFeedback.set(button, { originalLabel, timer });
}

/** Handle clicks from any descendant of a generated copy control. */
export async function handleClipboardClick(event, options = {}) {
  const button = event.target?.closest?.(COPY_SELECTOR);

  if (!button || button.disabled || button.getAttribute?.("aria-disabled") === "true") {
    return;
  }

  const copy = options.copy ?? copyTextToClipboard;

  try {
    await copy(button.dataset.fcCopyValue);
    showCopyFeedback(button, button.dataset.fcCopySuccess ?? "Copied", "success", options);
  } catch (_error) {
    showCopyFeedback(button, button.dataset.fcCopyFailure ?? "Copy failed", "error", options);
  }
}

/** Install one delegated listener so LiveView-patched copy controls also work. */
export function installClipboardBehavior(root = globalThis.document, options = {}) {
  if (!root?.addEventListener || root[COPY_LISTENER]) return;

  const listener = (event) => handleClipboardClick(event, options);
  root.addEventListener("click", listener);
  root[COPY_LISTENER] = listener;
}
