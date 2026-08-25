import { chromium } from "playwright";
import fs from "node:fs";
import path from "node:path";

function loadInstance() {
  const file = process.env.VERIFY_INSTANCE;
  if (!file) throw new Error("VERIFY_INSTANCE is unset");
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function evidenceDir(instance) {
  return instance.evidenceDir;
}

async function withPage(fn) {
  const instance = loadInstance();
  const browser = await chromium.launch({
    channel: "chrome",
    headless: process.env.VERIFY_HEADED === "1" ? false : true,
  });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    reducedMotion: "reduce",
  });
  const page = await context.newPage();
  const consoleErrors = [];
  page.on("console", (msg) => {
    if (msg.type() === "error") consoleErrors.push(msg.text());
  });
  page.on("pageerror", (err) => consoleErrors.push(String(err)));
  try {
    await fn({ page, instance, consoleErrors });
  } finally {
    await browser.close();
  }
}

async function waitReady(page) {
  await page.getByText(/api 127\.0\.0\.1:\d+/).waitFor({ timeout: 15_000 });
}

async function capture(page, instance, label, extra = {}) {
  const dir = evidenceDir(instance);
  fs.mkdirSync(dir, { recursive: true });
  const png = path.join(dir, `${label}.png`);
  const aria = path.join(dir, `${label}.aria.txt`);
  const meta = path.join(dir, `${label}.json`);
  await page.screenshot({ path: png, fullPage: true, animations: "disabled" });
  const snapshot = await page.locator("body").ariaSnapshot();
  fs.writeFileSync(aria, snapshot);
  fs.writeFileSync(
    meta,
    JSON.stringify(
      {
        url: page.url(),
        title: await page.title(),
        label,
        port: instance.port,
        skipAgent: instance.skipAgent,
        ...extra,
      },
      null,
      2,
    ),
  );
  return { png, aria, meta };
}

async function shot(pathname, label) {
  await withPage(async ({ page, instance, consoleErrors }) => {
    const url = `${instance.baseUrl}${pathname}`;
    await page.goto(url, { waitUntil: "networkidle" });
    await waitReady(page);
    const files = await capture(page, instance, label, { consoleErrors });
    process.stdout.write(JSON.stringify({ ok: true, url: page.url(), ...files }, null, 2) + "\n");
  });
}

async function rulesCreate(title, instruction) {
  await withPage(async ({ page, instance, consoleErrors }) => {
    await page.goto(`${instance.baseUrl}/rules`, { waitUntil: "networkidle" });
    await waitReady(page);
    await capture(page, instance, "rules-before", { consoleErrors: [...consoleErrors] });
    await page.getByRole("link", { name: "new semantic rule" }).click();
    await page.getByRole("heading", { name: "new semantic rule" }).waitFor();
    await page.getByLabel("title", { exact: true }).fill(title);
    await page.getByLabel("instruction").fill(instruction);
    await capture(page, instance, "rules-create-form", { consoleErrors: [...consoleErrors] });
    await page.getByRole("button", { name: "create" }).click();
    await page.waitForURL((url) => {
      const path = new URL(url).pathname;
      return path.startsWith("/rules/") && path !== "/rules/new";
    });
    await page.getByRole("button", { name: "save" }).waitFor();
    const files = await capture(page, instance, "rules-after", { consoleErrors });
    process.stdout.write(
      JSON.stringify({ ok: true, url: page.url(), rulePath: new URL(page.url()).pathname, ...files }, null, 2) +
        "\n",
    );
  });
}

async function agentsSave(id, extra) {
  await withPage(async ({ page, instance, consoleErrors }) => {
    await page.goto(`${instance.baseUrl}/agents`, { waitUntil: "networkidle" });
    await waitReady(page);
    await page.getByRole("heading", { name: "agents" }).waitFor();
    await capture(page, instance, "agents-before", { consoleErrors: [...consoleErrors] });
    await page.getByRole("tab", { name: new RegExp(`^${id}\\b`) }).click();
    const box = page.getByRole("textbox", { name: "prompt", exact: true });
    const current = await box.inputValue();
    await box.fill(`${current.trimEnd()}\n\n${extra}\n`);
    await capture(page, instance, "agents-edit", { consoleErrors: [...consoleErrors] });
    await page.getByRole("button", { name: "save", exact: true }).click();
    await page.getByText("saved", { exact: true }).waitFor();
    const files = await capture(page, instance, "agents-after", { consoleErrors });
    process.stdout.write(JSON.stringify({ ok: true, url: page.url(), id, ...files }, null, 2) + "\n");
  });
}

async function agentsReset(id) {
  await withPage(async ({ page, instance, consoleErrors }) => {
    await page.goto(`${instance.baseUrl}/agents`, { waitUntil: "networkidle" });
    await waitReady(page);
    await page.getByRole("heading", { name: "agents" }).waitFor();
    await page.getByRole("tab", { name: new RegExp(`^${id}\\b`) }).click();
    await capture(page, instance, "agents-reset-before", { consoleErrors: [...consoleErrors] });
    await page.getByRole("button", { name: "reset to default" }).click();
    await page.getByText("restored default").waitFor();
    const files = await capture(page, instance, "agents-reset-after", { consoleErrors });
    process.stdout.write(JSON.stringify({ ok: true, url: page.url(), id, ...files }, null, 2) + "\n");
  });
}

async function agentsReject(id) {
  await withPage(async ({ page, instance, consoleErrors }) => {
    await page.goto(`${instance.baseUrl}/agents`, { waitUntil: "networkidle" });
    await waitReady(page);
    await page.getByRole("heading", { name: "agents" }).waitFor();
    await page.getByRole("tab", { name: new RegExp(`^${id}\\b`) }).click();
    await capture(page, instance, "agents-reject-before", { consoleErrors: [...consoleErrors] });
    const box = page.getByRole("textbox", { name: "prompt", exact: true });
    await box.fill("---\ndescription: broken\nmode: primary\ntemperature: 0.2\n---\n\nno workspace files\n");
    await page.getByText("prompt is missing required paths").waitFor();
    await capture(page, instance, "agents-reject-edit", { consoleErrors: [...consoleErrors] });
    await page.getByRole("button", { name: "save", exact: true }).click();
    await page.locator(".formerr").filter({ hasText: "missing required paths" }).waitFor();
    const files = await capture(page, instance, "agents-reject-after", { consoleErrors });
    process.stdout.write(JSON.stringify({ ok: true, url: page.url(), id, ...files }, null, 2) + "\n");
  });
}

async function agentsImprove(id, instruction) {
  await withPage(async ({ page, instance, consoleErrors }) => {
    await page.goto(`${instance.baseUrl}/agents`, { waitUntil: "networkidle" });
    await waitReady(page);
    await page.getByRole("heading", { name: "agents" }).waitFor();
    await page.getByRole("tab", { name: new RegExp(`^${id}\\b`) }).click();
    await capture(page, instance, "agents-improve-before", { consoleErrors: [...consoleErrors] });
    await page.getByLabel("how should this prompt change").fill(instruction);
    await page.getByRole("button", { name: "improve", exact: true }).click();
    await page.locator(".formerr, .formok").first().waitFor({ timeout: 30_000 });
    const files = await capture(page, instance, "agents-improve-after", { consoleErrors });
    process.stdout.write(JSON.stringify({ ok: true, url: page.url(), id, ...files }, null, 2) + "\n");
  });
}

async function contextCreate(title, body) {
  await withPage(async ({ page, instance, consoleErrors }) => {
    await page.goto(`${instance.baseUrl}/context`, { waitUntil: "networkidle" });
    await waitReady(page);
    await capture(page, instance, "context-before", { consoleErrors: [...consoleErrors] });
    await page.getByRole("heading", { name: "new note" }).waitFor();
    await page.getByLabel("title", { exact: true }).fill(title);
    await page.getByLabel("body").fill(body);
    await capture(page, instance, "context-form", { consoleErrors: [...consoleErrors] });
    await page.getByRole("button", { name: "create" }).click();
    await page.getByText(title, { exact: true }).waitFor();
    const files = await capture(page, instance, "context-after", { consoleErrors });
    process.stdout.write(JSON.stringify({ ok: true, url: page.url(), ...files }, null, 2) + "\n");
  });
}

async function openJob(page, instance, jobId) {
  await page.goto(`${instance.baseUrl}/jobs/${jobId}`, { waitUntil: "networkidle" });
  await waitReady(page);
}

async function jobThumb(jobId, direction) {
  await withPage(async ({ page, instance, consoleErrors }) => {
    await openJob(page, instance, jobId);
    await capture(page, instance, `job-thumb-before`, { consoleErrors: [...consoleErrors] });
    const name = direction === "up" ? "👍" : "👎";
    await page.getByRole("button", { name }).first().click();
    await page.locator("button.on", { hasText: name }).first().waitFor({ timeout: 10_000 });
    const files = await capture(page, instance, `job-thumb-${direction}`, { consoleErrors });
    process.stdout.write(JSON.stringify({ ok: true, url: page.url(), jobId, direction, ...files }, null, 2) + "\n");
  });
}

async function jobMergeIntent(jobId, answer) {
  await withPage(async ({ page, instance, consoleErrors }) => {
    await openJob(page, instance, jobId);
    await capture(page, instance, "merge-intent-before", { consoleErrors: [...consoleErrors] });
    await page.getByText("would you have merged this unread?").waitFor();
    await page.getByRole("button", { name: answer, exact: true }).click();
    const labeled = answer === "yes" ? "labeled would merge unread" : "labeled would not merge unread";
    await page.getByText(labeled).waitFor({ timeout: 10_000 });
    const files = await capture(page, instance, `merge-intent-${answer}`, { consoleErrors });
    process.stdout.write(JSON.stringify({ ok: true, url: page.url(), jobId, answer, ...files }, null, 2) + "\n");
  });
}

async function jobLearn(jobId) {
  await withPage(async ({ page, instance, consoleErrors }) => {
    await openJob(page, instance, jobId);
    await capture(page, instance, "job-learn-before", { consoleErrors: [...consoleErrors] });
    await page.getByRole("button", { name: "learn", exact: true }).click();
    await page.getByText("learn queued").waitFor({ timeout: 15_000 });
    const href = await page.locator(".logline", { hasText: "learn queued" }).getByRole("link").getAttribute("href");
    const learnJobId = href ? href.replace("/jobs/", "") : "";
    const files = await capture(page, instance, "job-learn-after", { consoleErrors });
    process.stdout.write(
      JSON.stringify({ ok: true, url: page.url(), jobId, learnJobId, ...files }, null, 2) + "\n",
    );
  });
}

async function jobShouldBeRule(jobId) {
  await withPage(async ({ page, instance, consoleErrors }) => {
    await openJob(page, instance, jobId);
    await capture(page, instance, "should-be-rule-before", { consoleErrors: [...consoleErrors] });
    await page.getByRole("button", { name: "→ rule" }).first().click();
    await page.locator("button.on", { hasText: "→ rule" }).first().waitFor({ timeout: 10_000 });
    const files = await capture(page, instance, "should-be-rule-after", { consoleErrors });
    process.stdout.write(JSON.stringify({ ok: true, url: page.url(), jobId, ...files }, null, 2) + "\n");
  });
}

async function learningAccept(kind) {
  await withPage(async ({ page, instance, consoleErrors }) => {
    await page.goto(`${instance.baseUrl}/learnings`, { waitUntil: "networkidle" });
    await waitReady(page);
    await capture(page, instance, "learnings-before", { consoleErrors: [...consoleErrors] });
    const cards = page.locator(".learn");
    const count = await cards.count();
    let target = cards.first();
    if (kind) {
      let found = false;
      for (let i = 0; i < count; i += 1) {
        const text = (await cards.nth(i).innerText()).toLowerCase();
        if (text.includes(`${kind.toLowerCase()} ·`)) {
          target = cards.nth(i);
          found = true;
          break;
        }
      }
      if (!found) {
        throw new Error(`no pending learning of kind ${kind}`);
      }
    } else if (count === 0) {
      throw new Error("no pending learnings");
    }
    await Promise.all([
      page.waitForResponse((res) => res.url().includes("/accept") && res.ok()),
      target.getByRole("button", { name: "accept" }).click(),
    ]);
    const files = await capture(page, instance, "learnings-after-accept", { consoleErrors });
    process.stdout.write(JSON.stringify({ ok: true, url: page.url(), kind: kind || null, ...files }, null, 2) + "\n");
  });
}

async function rulePromote(id) {
  await withPage(async ({ page, instance, consoleErrors }) => {
    await page.goto(`${instance.baseUrl}/rules/${id}`, { waitUntil: "networkidle" });
    await waitReady(page);
    await capture(page, instance, "rule-promote-before", { consoleErrors: [...consoleErrors] });
    await page.getByRole("button", { name: "promote" }).click();
    await page.getByRole("button", { name: "save" }).waitFor({ timeout: 10_000 });
    const files = await capture(page, instance, "rule-promote-after", { consoleErrors });
    process.stdout.write(
      JSON.stringify({ ok: true, url: page.url(), rulePath: new URL(page.url()).pathname, ...files }, null, 2) + "\n",
    );
  });
}

async function ruleDisable(id) {
  await withPage(async ({ page, instance, consoleErrors }) => {
    await page.goto(`${instance.baseUrl}/rules`, { waitUntil: "networkidle" });
    await waitReady(page);
    await capture(page, instance, "rule-disable-before", { consoleErrors: [...consoleErrors] });
    const row = page.locator(".rule").filter({ has: page.locator(".rk", { hasText: `${id} ·` }) });
    await row.getByRole("button", { name: "disable" }).click();
    await row.getByRole("button", { name: "enable" }).waitFor({ timeout: 10_000 });
    const files = await capture(page, instance, "rule-disable-after", { consoleErrors });
    process.stdout.write(JSON.stringify({ ok: true, url: page.url(), id, ...files }, null, 2) + "\n");
  });
}

const cmd = process.argv[2];
if (cmd === "shot") {
  await shot(process.argv[3] ?? "/", process.argv[4] ?? "shot");
} else if (cmd === "rules-create") {
  await rulesCreate(process.argv[3], process.argv[4]);
} else if (cmd === "context-create") {
  await contextCreate(process.argv[3], process.argv[4]);
} else if (cmd === "agents-save") {
  await agentsSave(process.argv[3], process.argv[4]);
} else if (cmd === "agents-reset") {
  await agentsReset(process.argv[3]);
} else if (cmd === "agents-improve") {
  await agentsImprove(process.argv[3], process.argv[4]);
} else if (cmd === "agents-reject") {
  await agentsReject(process.argv[3]);
} else if (cmd === "job-thumb") {
  await jobThumb(process.argv[3], process.argv[4]);
} else if (cmd === "job-merge-intent") {
  await jobMergeIntent(process.argv[3], process.argv[4]);
} else if (cmd === "job-learn") {
  await jobLearn(process.argv[3]);
} else if (cmd === "job-should-be-rule") {
  await jobShouldBeRule(process.argv[3]);
} else if (cmd === "learning-accept") {
  await learningAccept(process.argv[3] ?? "");
} else if (cmd === "rule-promote") {
  await rulePromote(process.argv[3]);
} else if (cmd === "rule-disable") {
  await ruleDisable(process.argv[3]);
} else {
  process.stderr.write(
    "usage: browser.mjs shot|rules-create|context-create|agents-save|agents-reset|agents-improve|job-thumb|job-merge-intent|job-learn|job-should-be-rule|learning-accept|rule-promote|rule-disable ...\n",
  );
  process.exit(2);
}
