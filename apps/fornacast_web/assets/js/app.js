import { registerAll } from "@duskmoon-dev/elements";
import { registerAllArts } from "@duskmoon-dev/art-elements";

registerAll();
registerAllArts();

const themeStorageKey = "fornacast-theme";

const readStoredTheme = () => {
  try {
    return window.localStorage.getItem(themeStorageKey);
  } catch {
    return null;
  }
};

const storeTheme = (theme) => {
  try {
    window.localStorage.setItem(themeStorageKey, theme);
  } catch {
    return;
  }
};

const savedTheme = readStoredTheme();

if (savedTheme === "moonlight" || savedTheme === "sunshine") {
  document.documentElement.dataset.theme = savedTheme;
}

document.addEventListener("click", (event) => {
  if (!(event.target instanceof Element)) {
    return;
  }

  const button = event.target.closest("[data-theme-toggle]");

  if (!button) {
    return;
  }

  const root = document.documentElement;
  const nextTheme = root.dataset.theme === "moonlight" ? "sunshine" : "moonlight";
  root.dataset.theme = nextTheme;
  storeTheme(nextTheme);
});
