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

// WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#80
const writeClipboard = async (value, button) => {
  if (window.isSecureContext && typeof navigator.clipboard?.writeText === "function") {
    return navigator.clipboard.writeText(value);
  }

  const active = document.activeElement;
  const textarea = document.createElement("textarea");
  textarea.value = value;
  textarea.readOnly = true;
  textarea.style.position = "fixed";
  textarea.style.opacity = "0";
  document.body.append(textarea);
  textarea.select();

  try {
    if (!document.execCommand("copy")) {
      throw new Error("copy command rejected");
    }
  } finally {
    textarea.remove();

    if (active instanceof HTMLElement && active.isConnected) {
      active.focus();
    } else {
      button.focus();
    }
  }
};

document.addEventListener("click", async (event) => {
  if (!(event.target instanceof Element)) {
    return;
  }

  const button = event.target.closest("[data-copy-value]");

  if (!(button instanceof HTMLElement)) {
    return;
  }

  const page = button.closest("[data-repository-page]");
  const status = page?.querySelector("[data-copy-status]");

  if (status) {
    status.textContent = "";
  }

  try {
    await writeClipboard(button.dataset.copyValue || "", button);

    if (status) {
      status.textContent = "Copied to clipboard.";
    }
  } catch (_error) {
    if (status) {
      status.textContent = "Copy failed. Select and copy the value manually.";
    }
  }
});

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
