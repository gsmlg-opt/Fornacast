import assert from "node:assert/strict";
import { mock, test } from "node:test";

import {
  copyTextToClipboard,
  handleClipboardClick,
  installClipboardBehavior,
} from "../../assets/js/clipboard.js";

function copyControl(value) {
  const label = { textContent: "Copy" };
  const status = {
    textContent: "",
    matches: (selector) => selector === "[data-fc-copy-status]",
  };
  const button = {
    dataset: { fcCopyValue: value },
    disabled: false,
    getAttribute: () => null,
    nextElementSibling: status,
    querySelector: (selector) => (selector === "[data-fc-copy-label]" ? label : null),
  };
  const target = {
    closest: (selector) => (selector === "[data-fc-copy-value]" ? button : null),
  };

  return { button, label, status, target };
}

function delegatedRoot() {
  const listeners = new Map();

  return {
    addEventListener: mock.fn((event, listener) => listeners.set(event, listener)),
    listeners,
  };
}

const noReset = () => undefined;

test("copies the exact value from a descendant and announces success", async () => {
  const root = delegatedRoot();
  const value = "git clone https://example.test/acme/demo.git\n";
  const control = copyControl(value);
  const copy = mock.fn(async () => undefined);

  installClipboardBehavior(root, { copy, scheduleReset: noReset });
  await root.listeners.get("click")({ target: control.target });

  assert.deepEqual(copy.mock.calls[0].arguments, [value]);
  assert.equal(control.label.textContent, "Copied");
  assert.equal(control.status.textContent, "Copied");
  assert.equal(control.button.dataset.fcCopyState, "success");
});

test("announces clipboard failures", async () => {
  const control = copyControl("blob contents");
  const copy = async () => {
    throw new Error("permission denied");
  };

  await handleClipboardClick({ target: control.target }, { copy, scheduleReset: noReset });

  assert.equal(control.label.textContent, "Copy failed");
  assert.equal(control.status.textContent, "Copy failed");
  assert.equal(control.button.dataset.fcCopyState, "error");
});

test("uses the legacy copy command when Clipboard API is unavailable and restores focus", async () => {
  const activeElement = { focus: mock.fn() };
  const textArea = {
    focus: mock.fn(),
    select: mock.fn(),
    setAttribute: mock.fn(),
    style: {},
    value: "",
  };
  const body = {
    appendChild: mock.fn(),
    removeChild: mock.fn(),
  };
  const document = {
    activeElement,
    body,
    createElement: mock.fn(() => textArea),
    execCommand: mock.fn(() => true),
  };

  await copyTextToClipboard("fallback value", { document, navigator: {} });

  assert.equal(textArea.value, "fallback value");
  assert.deepEqual(document.execCommand.mock.calls[0].arguments, ["copy"]);
  assert.deepEqual(body.removeChild.mock.calls[0].arguments, [textArea]);
  assert.equal(activeElement.focus.mock.callCount(), 1);
});

test("does not fall back when Clipboard API rejects", async () => {
  const writeText = mock.fn(async () => {
    throw new Error("permission denied");
  });
  const document = { execCommand: mock.fn(() => true) };

  await assert.rejects(
    copyTextToClipboard("protected value", {
      document,
      navigator: { clipboard: { writeText } },
    }),
    /permission denied/,
  );

  assert.deepEqual(writeText.mock.calls[0].arguments, ["protected value"]);
  assert.equal(document.execCommand.mock.callCount(), 0);
});

test("uses secure Clipboard API when available", async () => {
  const writeText = mock.fn(async () => undefined);
  const document = { execCommand: mock.fn() };

  await copyTextToClipboard("secure value", {
    document,
    navigator: { clipboard: { writeText } },
  });

  assert.deepEqual(writeText.mock.calls[0].arguments, ["secure value"]);
  assert.equal(document.execCommand.mock.callCount(), 0);
});

test("cleans up and restores focus when legacy copy fails", async () => {
  const activeElement = { focus: mock.fn() };
  const textArea = {
    focus: mock.fn(),
    select: mock.fn(),
    setAttribute: mock.fn(),
    style: {},
  };
  const document = {
    activeElement,
    body: { appendChild: mock.fn(), removeChild: mock.fn() },
    createElement: () => textArea,
    execCommand: () => false,
  };

  await assert.rejects(
    copyTextToClipboard("value", { document, navigator: {} }),
    /Clipboard copy command failed/,
  );

  assert.equal(document.body.removeChild.mock.callCount(), 1);
  assert.equal(activeElement.focus.mock.callCount(), 1);
});

test("installs one listener per root even when DuskMoon has installed its own", async () => {
  const root = delegatedRoot();
  root[Symbol.for("phoenix-duskmoon.copy-listener")] = () => undefined;
  const control = copyControl("value");
  const copy = mock.fn(async () => undefined);

  installClipboardBehavior(root, { copy, scheduleReset: noReset });
  installClipboardBehavior(root, { copy, scheduleReset: noReset });
  await root.listeners.get("click")({ target: control.target });

  assert.equal(root.addEventListener.mock.callCount(), 1);
  assert.equal(copy.mock.callCount(), 1);
});

test("ignores disabled controls and unrelated upstream copy controls", async () => {
  const control = copyControl("value");
  const copy = mock.fn();
  const options = { copy, scheduleReset: noReset };

  control.button.disabled = true;
  await handleClipboardClick({ target: control.target }, options);
  control.button.disabled = false;
  control.button.getAttribute = () => "true";
  await handleClipboardClick({ target: control.target }, options);
  await handleClipboardClick(
    {
      target: {
        closest: (selector) => (selector === "[data-copy-value]" ? control.button : null),
      },
    },
    options,
  );

  assert.equal(copy.mock.callCount(), 0);
});

test("resets feedback after the latest copy without losing the original label", async () => {
  const control = copyControl("value");
  const timers = [];
  const cancelReset = mock.fn();
  const options = {
    copy: async () => undefined,
    cancelReset,
    scheduleReset: (callback, delay) => {
      timers.push({ callback, delay });
      return timers.length;
    },
  };

  await handleClipboardClick({ target: control.target }, options);
  await handleClipboardClick({ target: control.target }, options);

  assert.deepEqual(cancelReset.mock.calls[0].arguments, [1]);
  assert.equal(timers[1].delay, 2000);
  timers[1].callback();
  assert.equal(control.label.textContent, "Copy");
  assert.equal(control.status.textContent, "");
  assert.equal(control.button.dataset.fcCopyState, undefined);
});
