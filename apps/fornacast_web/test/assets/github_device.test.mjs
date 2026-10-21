import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(new URL("../../assets/js/github_device.js", import.meta.url), "utf8")
  .replace(/export \{ initGitHubDevicePolling \};/, "");
const settle = () => new Promise((resolve) => setImmediate(resolve));

function setup(response) {
  const feedback = { textContent: "Waiting" };
  const report = {
    dataset: { githubDeviceId: "opaque-id", interval: "5", expiresIn: "60" },
    isConnected: true,
    querySelector: () => feedback,
  };
  const timers = new Map();
  const requests = [];
  const redirects = [];
  const reloads = [];
  let now = 0;
  let pagehide;
  let pageshow;
  const context = vm.createContext({
    document: {
      querySelectorAll: () => [report],
      querySelector: () => ({ content: "csrf-token" }),
    },
    performance: { now: () => now },
    AbortController,
    window: {
      location: { assign: (url) => redirects.push(url), reload: () => reloads.push(true) },
      addEventListener: (name, callback) => {
        if (name === "pagehide") pagehide = callback;
        if (name === "pageshow") pageshow = callback;
      },
      setTimeout: (fn, delay) => { timers.set(fn, delay); return fn; },
      clearTimeout: (fn) => timers.delete(fn),
    },
    fetch: async (...args) => {
      requests.push(args);
      if (response instanceof Error) throw response;
      return typeof response === "function" ? response(...args) : response;
    },
  });
  vm.runInContext(`${source}\ninitGitHubDevicePolling();`, context);
  return { report, feedback, requests, timers, redirects, reloads,
    pagehide: () => pagehide(), setNow: (value) => { now = value; },
    pageshow: (persisted) => pageshow?.({ persisted }),
    tick: () => {
      const [fn, delay] = timers.entries().next().value;
      timers.delete(fn);
      now += delay;
      fn();
    },
  };
}

test("polling waits the minimum interval and posts with CSRF and same-origin credentials", async () => {
  const s = setup({ ok: true, json: async () => ({ status: "pending", interval: 10 }) });
  assert.equal(s.requests.length, 0);
  assert.deepEqual([...s.timers.values()], [5000]);
  s.tick();
  await settle();
  assert.equal(s.requests[0][0], "/settings/github/device/opaque-id/poll");
  assert.equal(s.requests[0][1].method, "POST");
  assert.equal(s.requests[0][1].headers["x-csrf-token"], "csrf-token");
  assert.equal(s.requests[0][1].credentials, "same-origin");
  assert.deepEqual([...s.timers.values()], [10000]);
});

test("completion navigates only to the fixed local account settings path", async () => {
  const s = setup({ ok: true, json: async () => ({ status: "complete", redirect: "https://evil.test" }) });
  s.tick();
  await settle();
  assert.deepEqual(s.redirects, ["/settings/github"]);
  assert.equal(s.timers.size, 0);
});

test("expired attempts stop before another exchange", async () => {
  const s = setup({ ok: true });
  s.setNow(60000);
  s.tick();
  await settle();
  assert.match(s.feedback.textContent, /expired/);
  assert.equal(s.requests.length, 0);
  assert.equal(s.timers.size, 0);
});

test("provider denial and session expiry stop polling with visible feedback", async () => {
  for (const response of [
    { status: 403, json: async () => ({ status: "failed", message: "GitHub authorization was declined." }) },
    { redirected: true },
  ]) {
    const s = setup(response);
    s.tick();
    await settle();
    assert.match(s.feedback.textContent, /declined|Sign in/);
    assert.equal(s.timers.size, 0);
  }
});

test("network failures retry without reducing the polling interval", async () => {
  const s = setup(new Error("offline"));
  s.tick();
  await settle();
  assert.match(s.feedback.textContent, /interrupted/);
  assert.deepEqual([...s.timers.values()], [5000]);
});

test("leaving the page aborts an outstanding exchange and stops timers", async () => {
  const s = setup((_url, options) => new Promise((_resolve, reject) => {
    options.signal.addEventListener("abort", () => reject(new Error("aborted")));
  }));
  s.tick();
  s.pagehide();
  await settle();
  assert.equal(s.requests[0][1].signal.aborted, true);
  assert.equal(s.timers.size, 0);
});

test("restoring a cached authorization page reloads its current server state", () => {
  const s = setup({ ok: true });
  s.pageshow(false);
  assert.equal(s.reloads.length, 0);
  s.pagehide();
  s.pageshow(true);
  assert.equal(s.reloads.length, 1);
});
