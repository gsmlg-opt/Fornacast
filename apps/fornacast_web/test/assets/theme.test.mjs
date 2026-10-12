import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(new URL("../../assets/js/app.js", import.meta.url), "utf8");
const themeCode = source.slice(source.indexOf("const themeModes"), source.indexOf("const initAppbarMenus"));

function setup(preference, dark = false, legacy = false) {
  let change;
  const query = { matches: dark };
  query[legacy ? "addListener" : "addEventListener"] = (...args) => { change = args.at(-1); };
  const dataset = { themePreference: preference };
  const context = vm.createContext({
    window: {
      matchMedia: () => query,
      localStorage: {
        getItem() { throw new Error("Theme must not read browser storage"); },
        setItem() { throw new Error("Theme must not write browser storage"); },
      },
    },
    document: { documentElement: { dataset } },
  });
  vm.runInContext(`${themeCode}\ninitTheme();`, context);
  return { dataset, change: (nextDark) => { query.matches = nextDark; change(); } };
}

test("auto resolves both system appearances and tracks changes", () => {
  for (const dark of [true, false]) {
    const session = setup("auto", dark);
    assert.equal(session.dataset.theme, dark ? "moonlight" : "sunshine");
    session.change(!dark);
    assert.equal(session.dataset.theme, dark ? "sunshine" : "moonlight");
    assert.equal(session.dataset.themePreference, "auto");
  }
});

test("the account preference overrides the system and old browser storage", () => {
  for (const preference of ["sunshine", "moonlight"]) {
    const session = setup(preference, true);
    session.change(false);
    assert.equal(session.dataset.theme, preference);
    assert.equal(session.dataset.themePreference, preference);
  }
});

test("missing or invalid preferences default to auto", () => {
  for (const preference of [undefined, "dark", ""]) {
    const session = setup(preference, true);
    assert.equal(session.dataset.theme, "moonlight");
    assert.equal(session.dataset.themePreference, "auto");
  }
});

test("auto supports legacy media query listeners", () => {
  const session = setup("auto", false, true);
  session.change(true);
  assert.equal(session.dataset.theme, "moonlight");
});

test("auto falls back to sunshine when matchMedia is unavailable", () => {
  const dataset = { themePreference: "auto" };
  const context = vm.createContext({ window: {}, document: { documentElement: { dataset } } });
  vm.runInContext(`${themeCode}\ninitTheme();`, context);
  assert.equal(dataset.theme, "sunshine");
});
