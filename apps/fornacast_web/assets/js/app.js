import "duskmoon_phoenix";
import "@duskmoon-dev/el-alert/register";
import { installClipboardBehavior } from "fornacast-component/clipboard";
import { initImportStatusPolling } from "./import_status.js";
import { initPatSyncStatusPolling } from "./pat_sync_status.js";
import { initGitHubDevicePolling } from "./github_device.js";

installClipboardBehavior();

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
    .querySelectorAll(".appbar-workspace-nav details, .appbar-actions details, .app-nav details")
    .forEach((menu) => {
      menu.addEventListener("toggle", () => {
        if (!menu.open) {
          return;
        }

        document
          .querySelectorAll(
            ".appbar-workspace-nav details[open], .appbar-actions details[open], .app-nav details[open]",
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
      initTheme();
      initAppbarMenus();
      initImportStatusPolling();
      initPatSyncStatusPolling();
      initGitHubDevicePolling();
    },
    { once: true },
  );
} else {
  initTheme();
  initAppbarMenus();
  initImportStatusPolling();
  initPatSyncStatusPolling();
  initGitHubDevicePolling();
}
