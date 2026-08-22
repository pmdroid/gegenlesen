import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { FormEvent, useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import type { RiskMode } from "../api";
import { getSettings, listOpenRouterModels, putSettings } from "../client";
import { ModelPicker } from "./ModelPicker";

const APPETITE = [
  { n: 1, copy: "only trivia" },
  { n: 2, copy: "small, boring" },
  { n: 3, copy: "typical small PR" },
  { n: 4, copy: "most clean changes" },
  { n: 5, copy: "everything the floor allows" },
] as const;

const SORTS = [
  { id: "most-popular", label: "popular" },
  { id: "coding-high-to-low", label: "coding" },
  { id: "intelligence-high-to-low", label: "intelligence" },
  { id: "top-weekly", label: "this week" },
  { id: "pricing-low-to-high", label: "cheap" },
  { id: "newest", label: "newest" },
] as const;

const CATEGORIES = [
  { id: "", label: "all" },
  { id: "programming", label: "programming" },
  { id: "technology", label: "technology" },
  { id: "academia", label: "academia" },
  { id: "science", label: "science" },
] as const;

export function SetupPage() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const settings = useQuery({ queryKey: ["settings"], queryFn: getSettings });

  const [modelA, setModelA] = useState("openrouter/deepseek/deepseek-v4-flash");
  const [modelB, setModelB] = useState("openrouter/google/gemini-3.7-flash");
  const [judge, setJudge] = useState("openrouter/openai/gpt-5.6-terra");
  const [scannerImage, setScannerImage] = useState("gegenlesen/scanner:0.1.0");
  const [apiKey, setApiKey] = useState("");
  const [debouncedKey, setDebouncedKey] = useState("");
  const [sort, setSort] = useState("coding-high-to-low");
  const [category, setCategory] = useState("");
  const [freeOnly, setFreeOnly] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [appetite, setAppetite] = useState(1);
  const [riskMode, setRiskMode] = useState<RiskMode>("shadow");

  useEffect(() => {
    const data = settings.data;
    if (!data) return;
    setModelA(data.models.model_a);
    setModelB(data.models.model_b);
    setJudge(data.judge_model);
    setScannerImage(data.scanner_image ?? "");
    setAppetite(data.risk.appetite);
    setRiskMode(data.risk.mode);
  }, [settings.data]);

  useEffect(() => {
    const handle = window.setTimeout(() => setDebouncedKey(apiKey.trim()), 450);
    return () => window.clearTimeout(handle);
  }, [apiKey]);

  const canFetch = Boolean(settings.data?.openrouter_configured || debouncedKey.length >= 20);
  const key = debouncedKey || undefined;

  const catalog = useQuery({
    queryKey: ["openrouter-models", "catalog", sort, freeOnly, key ?? "stored"],
    queryFn: () =>
      listOpenRouterModels({
        sort,
        limit: 200,
        free: freeOnly,
        key,
      }),
    enabled: canFetch,
    staleTime: 60_000,
  });

  const suggestions = useQuery({
    queryKey: ["openrouter-models", "suggest", category || "programming", freeOnly, key ?? "stored"],
    queryFn: () =>
      listOpenRouterModels({
        category: category || "programming",
        sort: "coding-high-to-low",
        free: freeOnly,
        key,
      }),
    enabled: canFetch,
    staleTime: 60_000,
  });

  const judgeSuggestions = useQuery({
    queryKey: ["openrouter-models", "suggest-judge", freeOnly, key ?? "stored"],
    queryFn: () =>
      listOpenRouterModels({
        sort: "intelligence-high-to-low",
        limit: 16,
        free: freeOnly,
        key,
      }),
    enabled: canFetch,
    staleTime: 60_000,
  });

  const save = useMutation({
    mutationFn: () =>
      putSettings({
        models: { model_a: modelA.trim(), model_b: modelB.trim() },
        judge_model: judge.trim(),
        openrouter_api_key: apiKey.trim() || undefined,
        scanner_image: scannerImage.trim(),
        risk: { mode: riskMode, appetite },
      }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["settings"] });
      navigate("/");
    },
    onError: (err: Error) => setError(err.message),
  });

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    if (!settings.data?.openrouter_configured && !apiKey.trim()) {
      setError("OpenRouter API key is required");
      return;
    }
    if (!modelA.trim() || !modelB.trim() || !judge.trim()) {
      setError("pick both reviewers and a judge");
      return;
    }
    save.mutate();
  }

  const firstRun = settings.data ? !settings.data.openrouter_configured : true;
  const models = catalog.data?.models ?? [];
  const catalogError = catalog.error instanceof Error ? catalog.error.message : null;

  return (
    <div className="page setup">
      <h1>{firstRun ? "set up gegenlesen" : "models and key"}</h1>
      <p className="neverapply">
        Paste an OpenRouter key and we load the live catalog. Search by name. Rankings come from
        OpenRouter, programming first for reviewers, intelligence for the judge.
      </p>
      <form className="form" onSubmit={onSubmit}>
        <label>
          OpenRouter API key
          <input
            type="password"
            autoComplete="off"
            value={apiKey}
            onChange={(event) => setApiKey(event.target.value)}
            placeholder={
              settings.data?.openrouter_configured ? "leave blank to keep the current key" : "sk-or-…"
            }
          />
        </label>
        <div className="picker-toolbar">
          <span>rank</span>
          {SORTS.map((item) => (
            <button
              type="button"
              key={item.id}
              className={sort === item.id ? "chip on" : "chip"}
              onClick={() => setSort(item.id)}
              disabled={!canFetch}
            >
              {item.label}
            </button>
          ))}
        </div>
        <div className="picker-toolbar">
          <span>price</span>
          <button
            type="button"
            className={freeOnly ? "chip on" : "chip"}
            onClick={() => setFreeOnly((on) => !on)}
            disabled={!canFetch}
          >
            free
          </button>
        </div>
        <div className="picker-toolbar">
          <span>category</span>
          {CATEGORIES.map((item) => (
            <button
              type="button"
              key={item.id || "all"}
              className={category === item.id ? "chip on" : "chip"}
              onClick={() => setCategory(item.id)}
              disabled={!canFetch}
            >
              {item.label}
            </button>
          ))}
        </div>
        {catalog.isFetching ? <div className="picker-hint">loading OpenRouter models…</div> : null}
        {catalogError ? <div className="formerr">{catalogError}</div> : null}
        <ModelPicker
          label="Reviewer A"
          value={modelA}
          onChange={setModelA}
          models={models}
          suggestions={suggestions.data?.models ?? []}
          disabled={!canFetch}
          placeholder={canFetch ? "type to filter" : "add a key first"}
        />
        <ModelPicker
          label="Reviewer B"
          value={modelB}
          onChange={setModelB}
          models={models}
          suggestions={suggestions.data?.models ?? []}
          disabled={!canFetch}
          placeholder={canFetch ? "type to filter" : "add a key first"}
        />
        <ModelPicker
          label="Judge"
          value={judge}
          onChange={setJudge}
          models={models}
          suggestions={judgeSuggestions.data?.models ?? []}
          disabled={!canFetch}
          placeholder={canFetch ? "type to filter" : "add a key first"}
        />
        <label>
          Scanner image
          <input
            type="text"
            autoComplete="off"
            spellCheck={false}
            value={scannerImage}
            onChange={(event) => setScannerImage(event.target.value)}
            placeholder="gegenlesen/scanner:0.1.0"
          />
          <span className="formhint">
            Docker image for Gitleaks and OSV. Leave blank to skip scanners.
          </span>
        </label>
        <h2>auto-approve</h2>
        <p className="neverapply">
          Hard safety checks always block: secrets, kept errors, a downed judge, a missing
          reviewer, unverifiable evidence. Higher levels only relax size, path surcharge, and
          warning tolerance.
        </p>
        <label>
          mode
          <select
            value={riskMode}
            onChange={(event) => setRiskMode(event.target.value as RiskMode)}
          >
            <option value="off">off</option>
            <option value="shadow">shadow</option>
            <option value="enforce">enforce</option>
          </select>
        </label>
        <div className="picker-toolbar">
          <span>appetite</span>
          {APPETITE.map((item) => (
            <button
              type="button"
              key={item.n}
              className={appetite === item.n ? "chip on" : "chip"}
              onClick={() => setAppetite(item.n)}
            >
              {item.n} · {item.copy}
            </button>
          ))}
        </div>
        {appetite >= 4 ? (
          <div className="formerr">most jobs will auto-approve at this level</div>
        ) : null}
        {error ? <div className="formerr">{error}</div> : null}
        <div className="formrow">
          <button type="submit" className="btn" disabled={save.isPending || settings.isLoading}>
            {save.isPending ? "saving…" : firstRun ? "save and continue" : "save"}
          </button>
        </div>
      </form>
    </div>
  );
}
