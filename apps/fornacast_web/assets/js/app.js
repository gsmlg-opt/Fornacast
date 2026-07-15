import { registerAll } from "@duskmoon-dev/elements";
import { registerAllArts } from "@duskmoon-dev/art-elements";

registerAll();
registerAllArts();

const themeStorageKey = "fornacast-theme";
const themeModes = ["auto", "sunshine", "moonlight"];
const concreteThemes = ["sunshine", "moonlight"];
const systemThemeQuery = window.matchMedia
  ? window.matchMedia("(prefers-color-scheme: dark)")
  : null;

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

const resolveTheme = (mode) => {
  if (concreteThemes.includes(mode)) {
    return mode;
  }

  return systemThemeQuery?.matches ? "moonlight" : "sunshine";
};

const closeContainingMenu = (element) => {
  const menu = element.closest("details");

  if (menu) {
    menu.open = false;
  }
};

const setTheme = (mode, options = {}) => {
  const nextMode = themeModes.includes(mode) ? mode : "auto";
  const nextTheme = resolveTheme(nextMode);

  document.documentElement.dataset.theme = nextTheme;
  document.documentElement.dataset.themePreference = nextMode;

  document.querySelectorAll("[data-theme-choice]").forEach((button) => {
    const isSelected = button.dataset.themeChoice === nextMode;
    button.setAttribute("aria-checked", String(isSelected));
  });

  if (options.persist) {
    storeTheme(nextMode);
  }
};

const initThemeMenu = () => {
  const savedThemeMode = readStoredTheme();
  setTheme(savedThemeMode || "auto");

  document.querySelectorAll("[data-theme-choice]").forEach((button) => {
    button.addEventListener("click", () => {
      setTheme(button.dataset.themeChoice, { persist: true });
      closeContainingMenu(button);
    });
  });

  const refreshAutoTheme = () => {
    if (document.documentElement.dataset.themePreference === "auto") {
      setTheme("auto");
    }
  };

  if (systemThemeQuery?.addEventListener) {
    systemThemeQuery.addEventListener("change", refreshAutoTheme);
  } else if (systemThemeQuery?.addListener) {
    systemThemeQuery.addListener(refreshAutoTheme);
  }
};

const initAppbarMenus = () => {
  document
    .querySelectorAll(".appbar-nav details, .appbar-actions details, .app-nav details")
    .forEach((menu) => {
      menu.addEventListener("toggle", () => {
        if (!menu.open) {
          return;
        }

        document
          .querySelectorAll(
            ".appbar-nav details[open], .appbar-actions details[open], .app-nav details[open]",
          )
          .forEach((openMenu) => {
            if (openMenu !== menu) {
              openMenu.open = false;
            }
          });
      });
    });
};

if (document.readyState === "loading") {
  document.addEventListener(
    "DOMContentLoaded",
    () => {
      initThemeMenu();
      initAppbarMenus();
    },
    { once: true },
  );
} else {
  initThemeMenu();
  initAppbarMenus();
}
