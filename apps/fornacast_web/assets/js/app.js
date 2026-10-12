import "phoenix_duskmoon";
import { installClipboardBehavior } from "fornacast-component/clipboard";
// TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#104
// TODO(upstream): duskmoon-dev/duskmoon-elements#83
// TODO(upstream): duskmoon-dev/duskmoon-elements#85 - update transitive KaTeX when fixed upstream.
import { registerAll } from "@duskmoon-dev/elements";
import { registerAllArts } from "@duskmoon-dev/art-elements";
import { initImportStatusPolling } from "./import_status.js";
import { initPatSyncStatusPolling } from "./pat_sync_status.js";

installClipboardBehavior();
registerAll();
registerAllArts();

const themeModes = ["auto", "sunshine", "moonlight"];
const systemThemeQuery = window.matchMedia
  ? window.matchMedia("(prefers-color-scheme: dark)")
  : null;

const setTheme = (mode) => {
  const preference = themeModes.includes(mode) ? mode : "auto";
  const theme =
    preference === "auto" ? (systemThemeQuery?.matches ? "moonlight" : "sunshine") : preference;

  document.documentElement.dataset.theme = theme;
  document.documentElement.dataset.themePreference = preference;
};

const initTheme = () => {
  setTheme(document.documentElement.dataset.themePreference);

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

// TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#92
// WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#92
const initRepositoryClonePopoverFocus = () => {
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") {
      return;
    }

    const popover = document.querySelector("[data-clone-popover][open]");
    const trigger = popover?.querySelector("[data-clone-trigger]");

    if (!(trigger instanceof HTMLElement)) {
      return;
    }

    window.requestAnimationFrame(() => {
      if (!popover.hasAttribute("open") && trigger.isConnected) {
        trigger.focus();
      }
    });
  });
};

if (document.readyState === "loading") {
  document.addEventListener(
    "DOMContentLoaded",
    () => {
      initTheme();
      initAppbarMenus();
      initRepositoryClonePopoverFocus();
      initImportStatusPolling();
      initPatSyncStatusPolling();
    },
    { once: true },
  );
} else {
  initTheme();
  initAppbarMenus();
  initRepositoryClonePopoverFocus();
  initImportStatusPolling();
  initPatSyncStatusPolling();
}
