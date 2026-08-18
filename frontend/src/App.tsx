import { useQuery } from "@tanstack/react-query";
import { NavLink, Route, Routes } from "react-router-dom";
import { getHealth, getSettings } from "./client";
import { ContextPage } from "./pages/Context";
import { JobsPage } from "./pages/Jobs";
import { LearningsPage } from "./pages/Learnings";
import { RuleEditorPage } from "./pages/RuleEditor";
import { RulesPage } from "./pages/Rules";

export function App() {
  const health = useQuery({ queryKey: ["health"], queryFn: getHealth });
  const settings = useQuery({ queryKey: ["settings"], queryFn: getSettings });

  const bind = settings.data?.bind ?? "127.0.0.1";
  const port = settings.data?.port ?? 8080;
  const apiLabel = health.data?.ok
    ? `api ${bind}:${port} · ${health.data.version}`
    : health.isError
      ? "api down"
      : "api …";

  return (
    <>
      <div className="topbar">
        <span className="brand">MEISTER</span>
        <nav>
          <NavLink to="/" end className={({ isActive }) => (isActive ? "on" : undefined)}>
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
        </nav>
        <span className="srv">{apiLabel}</span>
      </div>
      <Routes>
        <Route path="/" element={<JobsPage />} />
        <Route path="/rules" element={<RulesPage />} />
        <Route path="/rules/new" element={<RuleEditorPage />} />
        <Route path="/rules/:id" element={<RuleEditorPage />} />
        <Route path="/context" element={<ContextPage />} />
        <Route path="/learnings" element={<LearningsPage />} />
      </Routes>
    </>
  );
}
