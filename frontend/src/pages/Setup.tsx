import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { FormEvent, useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import type { RiskMode } from "../api";
import { getSettings, listOpenRouterModels, putSettings } from "../client";
import { EnginePicker } from "../components/EnginePicker";
import { EngineAuthHint } from "../components/EngineAuthHint";
import { useEngineModels } from "../hooks/useEngineModels";
import { ENGINE_IDS, modelPlaceholder, normalizeEngine, reconcileModelForEngine, validateModelForEngine, type EngineId } from "../engines";
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
  const [engineA, setEngineA] = useState<EngineId>("opencode");
  const [engineB, setEngineB] = useState<EngineId>("opencode");
  const [judgeEngine, setJudgeEngine] = useState<EngineId>("opencode");
  const [judge, setJudge] = useState("openrouter/openai/gpt-5.6-terra");
  const [miner, setMiner] = useState("openrouter/openai/gpt-5.6-terra");
  const [mineEngine, setMineEngine] = useState<EngineId>("opencode");
  const [learnEngine, setLearnEngine] = useState<EngineId>("opencode");
  const [learnModel, setLearnModel] = useState("openrouter/openai/gpt-5.6-terra");
  const [scannerImage, setScannerImage] = useState("gegenlesen/scanner:0.1.0");
  const [apiKey, setApiKey] = useState("");
  const [debouncedKey, setDebouncedKey] = useState("");
  const [sort, setSort] = useState("coding-high-to-low");
  const [category, setCategory] = useState("");
  const [freeOnly, setFreeOnly] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [appetite, setAppetite] = useState(1);
  const [riskMode, setRiskMode] = useState<RiskMode>("shadow");
  const [learnMinutes, setLearnMinutes] = useState(0);

  useEffect(() => {
    const data = settings.data;
    if (!data) return;
    setModelA(data.models.model_a);
    setModelB(data.models.model_b);
    setEngineA(normalizeEngine(data.models.engine_a));
    setEngineB(normalizeEngine(data.models.engine_b));
    setJudgeEngine(normalizeEngine(data.judge_engine));
    setJudge(data.judge_model);
    setMiner(data.miner_model || data.engine_profiles?.mine.model || data.judge_model);
    setMineEngine(normalizeEngine(data.engine_profiles?.mine.engine));
    setLearnEngine(normalizeEngine(data.engine_profiles?.learn.engine));
    setLearnModel(data.engine_profiles?.learn.model ?? data.miner_model ?? data.judge_model);
    setScannerImage(data.scanner_image ?? "");
    setAppetite(data.risk.appetite);
    setRiskMode(data.risk.mode);
    setLearnMinutes(data.limits.learn_interval_minutes ?? 0);
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
        models: {
          engine_a: engineA,
          model_a: modelA.trim(),
          engine_b: engineB,
          model_b: modelB.trim(),
        },
        judge_engine: judgeEngine,
        judge_model: judge.trim(),
        miner_model: miner.trim(),
        engine_profiles: {
          mine: { engine: mineEngine, model: miner.trim() },
          learn: { engine: learnEngine, model: learnModel.trim() },
        },
        openrouter_api_key: apiKey.trim() || undefined,
        scanner_image: scannerImage.trim(),
        risk: { mode: riskMode, appetite },
        limits: { learn_interval_minutes: learnMinutes },
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
    const usesOpenCode = [engineA, engineB, judgeEngine, mineEngine, learnEngine].some((e) => e === "opencode");
    if (usesOpenCode && !settings.data?.openrouter_configured && !apiKey.trim()) {
      setError("OpenRouter API key is required when any slot uses OpenCode");
      return;
    }
    if (!modelA.trim() || !modelB.trim() || !judge.trim() || !miner.trim() || !learnModel.trim()) {
      setError("pick both reviewers, a judge, and mine/learn models");
      return;
    }
    for (const [label, engine, model] of [
      ["Reviewer A", engineA, modelA],
      ["Reviewer B", engineB, modelB],
      ["Judge", judgeEngine, judge],
      ["Mine", mineEngine, miner],
      ["Learn", learnEngine, learnModel],
    ] as const) {
      const issue = validateModelForEngine(engine, model);
      if (issue) {
        setError(`${label}: ${issue}`);
        return;
      }
    }
    if (!(ENGINE_IDS as readonly string[]).includes(engineA) ||
        !(ENGINE_IDS as readonly string[]).includes(engineB) ||
        !(ENGINE_IDS as readonly string[]).includes(judgeEngine) ||
        !(ENGINE_IDS as readonly string[]).includes(mineEngine) ||
        !(ENGINE_IDS as readonly string[]).includes(learnEngine)) {
      setError("pick a known engine for each slot");
      return;
    }
    save.mutate();
  }

  const firstRun = settings.data ? !settings.data.openrouter_configured : true;
  const engineAuth = settings.data?.engine_auth;
  const modelsAcp = useEngineModels(engineA, engineAuth);
  const modelsBcp = useEngineModels(engineB, engineAuth);
  const judgeAcp = useEngineModels(judgeEngine, engineAuth);
  const mineAcp = useEngineModels(mineEngine, engineAuth);
  const learnAcp = useEngineModels(learnEngine, engineAuth);
  const models = catalog.data?.models ?? [];
  const catalogError = catalog.error instanceof Error ? catalog.error.message : null;

  return (
    <div className="page setup">
      <h1>{firstRun ? "set up gegenlesen" : "models and key"}</h1>
      <p className="neverapply">
        OpenCode slots use the live OpenRouter catalog. Claude, Codex, Cursor, and Grok model lists are
        fetched live from each engine's ACP agent using your host credentials — not a hardcoded catalog.
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
        <div className="slot-setup">
          <EnginePicker
            label="Reviewer A engine"
            value={engineA}
            onChange={(next) => {
              setEngineA(next);
              setModelA((prev) => reconcileModelForEngine(next, prev, modelsAcp.data?.models));
            }}
            disabled={false}
          />
          <EngineAuthHint engine={engineA} engineAuth={engineAuth} />
          <ModelPicker
            label="Reviewer A model"
            engine={engineA}
            value={modelA}
            onChange={setModelA}
            models={models}
            suggestions={suggestions.data?.models ?? []}
            nativeModels={modelsAcp.data?.models}
            nativeLoading={modelsAcp.isFetching}
            nativeError={modelsAcp.error instanceof Error ? modelsAcp.error.message : null}
            disabled={(!canFetch && engineA === "opencode") || (engineA !== "opencode" && modelsAcp.isFetching)}
            placeholder={canFetch || engineA !== "opencode" ? modelPlaceholder(engineA) : "add OpenRouter key first"}
            error={validateModelForEngine(engineA, modelA)}
          />
        </div>
        <div className="slot-setup">
          <EnginePicker
            label="Reviewer B engine"
            value={engineB}
            onChange={(next) => {
              setEngineB(next);
              setModelB((prev) => reconcileModelForEngine(next, prev, modelsBcp.data?.models));
            }}
            disabled={false}
          />
          <EngineAuthHint engine={engineB} engineAuth={engineAuth} />
          <ModelPicker
            label="Reviewer B model"
            engine={engineB}
            value={modelB}
            onChange={setModelB}
            models={models}
            suggestions={suggestions.data?.models ?? []}
            nativeModels={modelsBcp.data?.models}
            nativeLoading={modelsBcp.isFetching}
            nativeError={modelsBcp.error instanceof Error ? modelsBcp.error.message : null}
            disabled={(!canFetch && engineB === "opencode") || (engineB !== "opencode" && modelsBcp.isFetching)}
            placeholder={canFetch || engineB !== "opencode" ? modelPlaceholder(engineB) : "add OpenRouter key first"}
            error={validateModelForEngine(engineB, modelB)}
          />
        </div>
        <div className="slot-setup">
          <EnginePicker
            label="Judge engine"
            value={judgeEngine}
            onChange={(next) => {
              setJudgeEngine(next);
              setJudge((prev) => reconcileModelForEngine(next, prev, judgeAcp.data?.models));
            }}
            disabled={false}
          />
          <EngineAuthHint engine={judgeEngine} engineAuth={engineAuth} />
          <ModelPicker
            label="Judge model"
            engine={judgeEngine}
            value={judge}
            onChange={setJudge}
            models={models}
            suggestions={judgeSuggestions.data?.models ?? []}
            nativeModels={judgeAcp.data?.models}
            nativeLoading={judgeAcp.isFetching}
            nativeError={judgeAcp.error instanceof Error ? judgeAcp.error.message : null}
            disabled={(!canFetch && judgeEngine === "opencode") || (judgeEngine !== "opencode" && judgeAcp.isFetching)}
            placeholder={canFetch || judgeEngine !== "opencode" ? modelPlaceholder(judgeEngine) : "add OpenRouter key first"}
            error={validateModelForEngine(judgeEngine, judge)}
          />
        </div>
        <div className="slot-setup">
          <EnginePicker
            label="Mine engine"
            value={mineEngine}
            onChange={(next) => {
              setMineEngine(next);
              setMiner((prev) => reconcileModelForEngine(next, prev, mineAcp.data?.models));
            }}
            disabled={false}
          />
          <EngineAuthHint engine={mineEngine} engineAuth={engineAuth} />
          <ModelPicker
            label="Mine model"
            engine={mineEngine}
            value={miner}
            onChange={setMiner}
            models={models}
            suggestions={suggestions.data?.models ?? []}
            nativeModels={mineAcp.data?.models}
            nativeLoading={mineAcp.isFetching}
            nativeError={mineAcp.error instanceof Error ? mineAcp.error.message : null}
            disabled={(!canFetch && mineEngine === "opencode") || (mineEngine !== "opencode" && mineAcp.isFetching)}
            placeholder={canFetch || mineEngine !== "opencode" ? modelPlaceholder(mineEngine) : "add OpenRouter key first"}
            error={validateModelForEngine(mineEngine, miner)}
          />
        </div>
        <div className="slot-setup">
          <EnginePicker
            label="Learn engine"
            value={learnEngine}
            onChange={(next) => {
              setLearnEngine(next);
              setLearnModel((prev) => reconcileModelForEngine(next, prev, learnAcp.data?.models));
            }}
            disabled={false}
          />
          <EngineAuthHint engine={learnEngine} engineAuth={engineAuth} />
          <ModelPicker
            label="Learn model"
            engine={learnEngine}
            value={learnModel}
            onChange={setLearnModel}
            models={models}
            suggestions={suggestions.data?.models ?? []}
            nativeModels={learnAcp.data?.models}
            nativeLoading={learnAcp.isFetching}
            nativeError={learnAcp.error instanceof Error ? learnAcp.error.message : null}
            disabled={(!canFetch && learnEngine === "opencode") || (learnEngine !== "opencode" && learnAcp.isFetching)}
            placeholder={canFetch || learnEngine !== "opencode" ? modelPlaceholder(learnEngine) : "add OpenRouter key first"}
            error={validateModelForEngine(learnEngine, learnModel)}
          />
        </div>
        <p className="formhint">
          Harvest, learn, and architecture cards. Independent of the findings judge. A stronger
          model usually mines better rules, and costs more.
        </p>
        <label>
          Scanner image
          <input
            type="text"
            autoComplete="off"
            spellCheck={false}
            value={scannerImage}
            onChange={(event) => setScannerImage(event.target.value)}
            placeholder="ghcr.io/pmdroid/gegenlesen:scanner-main"
          />
          <span className="formhint">
            Docker image for Gitleaks and OSV. Published tag is
            ghcr.io/pmdroid/gegenlesen:scanner-main. From source, build
            gegenlesen/scanner:0.1.0. Leave blank to skip scanners.
          </span>
        </label>
        <label>
          Learn every (minutes)
          <input
            type="number"
            min={0}
            step={1}
            value={learnMinutes}
            onChange={(event) => {
              const next = Number(event.target.value);
              setLearnMinutes(Number.isFinite(next) ? Math.max(0, Math.floor(next)) : 0);
            }}
          />
          <span className="formhint">
            0 means off. Thumbs and merge-intent only mark what to learn. The Learn button always
            works. When set, a tick runs at most this often while the agent slot is free.
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
