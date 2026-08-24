import { useEffect, useState } from "react";
import {
  applyTheme,
  nextThemePreference,
  readThemePreference,
  resolveTheme,
  type ThemePreference,
  writeThemePreference,
} from "../theme";

export function ThemeToggle() {
  const [preference, setPreference] = useState<ThemePreference>(readThemePreference);

  useEffect(() => {
    applyTheme(resolveTheme(preference));
    writeThemePreference(preference);
    if (preference !== "system") return;
    const media = window.matchMedia("(prefers-color-scheme: light)");
    const onChange = () => applyTheme(resolveTheme("system"));
    media.addEventListener("change", onChange);
    return () => media.removeEventListener("change", onChange);
  }, [preference]);

  const resolved = resolveTheme(preference);
  const label = preference === "system" ? `system (${resolved})` : preference;

  return (
    <button
      type="button"
      className="chip theme-toggle"
      onClick={() => setPreference(nextThemePreference(preference))}
      title="Theme: system follows the OS. Click to cycle system → light/dark."
    >
      {label}
    </button>
  );
}
