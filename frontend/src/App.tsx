import { useQuery } from "@tanstack/react-query";
import { NavLink, Navigate, Route, Routes, useLocation } from "react-router-dom";
import { getHealth, getSettings } from "./client";
import { ContextPage } from "./pages/Context";
import { JobDetailPage } from "./pages/JobDetail";
import { JobsPage } from "./pages/Jobs";
import { LearningsPage } from "./pages/Learnings";
import { RuleEditorPage } from "./pages/RuleEditor";
import { RulesPage } from "./pages/Rules";
import { SetupPage } from "./pages/Setup";

export function App() {
  const location = useLocation();
  const jobsOn = location.pathname === "/" || location.pathname.startsWith("/jobs/");
  const health = useQuery({ queryKey: ["health"], queryFn: getHealth });
  const settings = useQuery({ queryKey: ["settings"], queryFn: getSettings });

  const bind = settings.data?.bind ?? "127.0.0.1";
  const port = settings.data?.port ?? 8080;
  const apiLabel = health.data?.ok
    ? `api ${bind}:${port} · ${health.data.version}`
    : health.isError
      ? "api down"
      : "api …";
  const needsSetup =
    Boolean(settings.data) &&
    !settings.data?.openrouter_configured &&
    location.pathname !== "/setup";

  return (
    <>
      <div className="topbar">
        <span className="brand">gegenlesen</span>
        <nav>
          <NavLink to="/" className={jobsOn ? "on" : undefined}>
            jobs
          </NavLink>
          <NavLink to="/rules" className={({ isActive }) => (isActive ? "on" : undefined)}>
            rules
          </NavLink>
          <NavLink to="/context" className={({ isActive }) => (isActive ? "on" : undefined)}>
            context
          </NavLink>
          <NavLink to="/learnings" className={({ isActive }) => (isActive ? "on" : undefined)}>
            learnings
          </NavLink>
          <NavLink to="/setup" className={({ isActive }) => (isActive ? "on" : undefined)}>
            setup
          </NavLink>
        </nav>
        <span className="srv">{apiLabel}</span>
      </div>
      {needsSetup ? <Navigate to="/setup" replace /> : null}
      <Routes>
        <Route path="/" element={<JobsPage />} />
        <Route path="/jobs/:id" element={<JobDetailPage />} />
        <Route path="/rules" element={<RulesPage />} />
        <Route path="/rules/new" element={<RuleEditorPage />} />
        <Route path="/rules/:id" element={<RuleEditorPage />} />
        <Route path="/context" element={<ContextPage />} />
        <Route path="/learnings" element={<LearningsPage />} />
        <Route path="/setup" element={<SetupPage />} />
      </Routes>
    </>
  );
}
