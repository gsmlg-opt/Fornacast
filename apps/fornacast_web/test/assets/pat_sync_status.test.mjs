import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(new URL("../../assets/js/pat_sync_status.js", import.meta.url), "utf8").replace(/export \{ initPatSyncStatusPolling \};/, "");
const settle = () => new Promise((resolve) => setImmediate(resolve));
function report(poll = "true") {
  const feedback = { textContent: "" };
  return {
    dataset: { patSyncPoll: poll, patSyncStatusUrl: "/canonical/runs/12/status", patSyncUpdatedAt: "2026-10-15T01:00:00Z" },
    isConnected: true,
    feedback,
    querySelector(selector) { return selector === "details" ? null : feedback; },
    replaceWith(next) { this.isConnected = false; next.isConnected = true; this.replacement = next; },
  };
}
function setup(response, nextPoll = "false") {
  const initial = report();
  const next = report(nextPoll);
  const requests = [];
  const timers = [];
  const context = vm.createContext({
    document: { querySelectorAll: () => [initial] },
    AbortController,
    window: { location: { href: "/pat/check" }, setTimeout: (fn) => { timers.push(fn); return fn; }, clearTimeout: (fn) => { const index = timers.indexOf(fn); if (index >= 0) timers.splice(index, 1); } },
    fetch: async (...args) => { requests.push(args); if (response instanceof Error) throw response; return typeof response === "function" ? response(...args) : response; },
    DOMParser: class { parseFromString() { return { querySelector: () => next }; } },
  });
  vm.runInContext(`${source}\ninitPatSyncStatusPolling();`, context);
  return { initial, next, requests, timers };
}

test("queued empty reports poll immediately using the canonical JSON task endpoint", async () => {
  const s = setup({ ok: true, json: async () => ({ html: "report", run: { terminal: true, observed_at: "now" } }) });
  assert.equal(s.requests.length, 1);
  assert.equal(s.requests[0][0], "/canonical/runs/12/status");
  assert.equal(s.requests[0][1].headers.Accept, "application/json");
  await settle();
  assert.equal(s.initial.replacement, s.next);
  assert.match(s.next.feedback.textContent, /Task finished/);
  assert.equal(s.timers.length, 0);
});

test("terminal response replaces the entire report including headline, counts and actions", async () => {
  const s = setup({ ok: true, json: async () => ({ html: "terminal report", run: { terminal: true, observed_at: "now" } }) });
  await settle();
  assert.equal(s.initial.isConnected, false);
  assert.equal(s.next.dataset.patSyncPoll, "false");
  assert.equal(s.next.dataset.patSyncConnection, "connected");
});

for (const response of [new Error("offline"), { ok: false, status: 503 }, { ok: true, json: async () => ({}) }]) {
  test(`network or invalid status remains visible and retries (${response.status || response.message || "invalid"})`, async () => {
    const s = setup(response);
    await settle();
    assert.equal(s.initial.dataset.patSyncConnection, "stale");
    assert.match(s.initial.feedback.textContent, /may be stale/);
    assert.equal(s.timers.length, 1);
  });
}

for (const response of [{ status: 401 }, { redirected: true }, { status: 404 }]) {
  test(`authentication/access failure visibly stops polling (${response.status || "redirect"})`, async () => {
    const s = setup(response);
    await settle();
    assert.match(s.initial.feedback.textContent, /stopped/);
    assert.equal(s.timers.length, 0);
  });
}

test("active task keeps polling after replacing its saved progress", async () => {
  const s = setup({ ok: true, json: async () => ({ html: "running", run: { terminal: false, observed_at: "now" } }) }, "true");
  await settle();
  assert.equal(s.initial.replacement, s.next);
  assert.match(s.next.feedback.textContent, /connected/);
  assert.equal(s.timers.length, 1);
});

test("a hung status request times out visibly and schedules recovery", async () => {
  const s = setup((_url, options) => new Promise((_resolve, reject) => {
    options.signal.addEventListener("abort", () => reject(new Error("timeout")));
  }));
  assert.equal(s.timers.length, 1);
  s.timers[0]();
  await settle();
  assert.equal(s.initial.dataset.patSyncConnection, "stale");
  assert.match(s.initial.feedback.textContent, /retrying/);
  assert.equal(s.timers.length, 1);
});
