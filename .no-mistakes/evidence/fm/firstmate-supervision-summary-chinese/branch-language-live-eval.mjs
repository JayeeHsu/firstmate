import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const root = process.cwd();
const packageRoot = "/Users/shanque/.nvm/versions/node/v22.22.2/lib/node_modules/@earendil-works/pi-coding-agent";
const {
  createAgentSession,
  DefaultResourceLoader,
  defineTool,
  getAgentDir,
  ModelRuntime,
  SessionManager,
  SettingsManager,
} = await import(pathToFileURL(`${packageRoot}/dist/index.js`).href);

const systemPrompt = execFileSync(`${root}/bin/fm-branch-prompt.sh`, [], { encoding: "utf8" });
const runtime = await ModelRuntime.create({
  authPath: `${getAgentDir()}/auth.json`,
  modelsPath: `${getAgentDir()}/models.json`,
});
const provider = process.env.PI_PROVIDER;
const modelId = process.env.PI_MODEL;
const model = runtime.getModel(provider, modelId);
if (!model) throw new Error(`configured model unavailable: ${provider}/${modelId}`);

const scenarios = [
  {
    name: "latest Chinese captain mirror",
    mirror: "[captain] 最近请用中文简洁汇报。",
    durablePreference: "Captain prefers English.",
    expected: "zh",
  },
  {
    name: "latest English captain mirror",
    mirror: "[captain] Please keep routine supervision summaries concise and in English.",
    durablePreference: "Captain prefers Chinese: 中文。",
    expected: "en",
  },
  {
    name: "latest Spanish captain mirror",
    mirror: "[captain] Por favor, mantén los resúmenes rutinarios breves y en español.",
    durablePreference: "Captain prefers English.",
    expected: "es",
  },
  {
    name: "mirrorless split-home durable Chinese preference",
    mirror: null,
    durablePreference: "Captain's durable language preference: concise Chinese (中文).",
    expected: "zh",
    requirePreferenceRead: true,
  },
];

const transcript = {
  commit: execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim(),
  model: `${provider}/${modelId}`,
  scenarios: [],
};

for (const scenario of scenarios) {
  const bashCalls = [];
  const reports = [];
  const bashTool = defineTool({
    name: "bash",
    label: "bash",
    description: "Execute a supervision command in the active Firstmate home.",
    parameters: {
      type: "object",
      properties: { command: { type: "string" } },
      required: ["command"],
      additionalProperties: false,
    },
    execute: async (_id, params) => {
      bashCalls.push(params.command);
      let text = "ok";
      if (params.command.includes("fm-wake-drain.sh") && !params.command.includes("--ack-through")) {
        text = [
          "FIRSTMATE SUPERVISION WAKE: signal: task-lang completed normally",
          "task-lang completed its focused checks; no action is required.",
          "WAKE_ACK_REQUIRED: bin/fm-wake-drain.sh --ack-through 1",
        ].join("\n");
      } else if (params.command.includes("fm-crew-state.sh")) {
        text = "task-lang: done; focused checks passed; no blocker";
      } else if (params.command.includes("captain.md")) {
        text = scenario.durablePreference;
      }
      return { content: [{ type: "text", text }], details: {} };
    },
  });
  const reportTool = defineTool({
    name: "fm_branch_report",
    label: "fm_branch_report",
    description: "Durably report one handled supervision outcome.",
    parameters: {
      type: "object",
      properties: {
        task: { type: "string" },
        verdict: { type: "string", enum: ["routine", "captain"] },
        summary: { type: "string" },
        wake: { type: "string" },
        silent: { type: "boolean" },
      },
      required: ["task", "verdict", "summary"],
      additionalProperties: false,
    },
    execute: async (_id, params) => {
      reports.push(params);
      return { content: [{ type: "text", text: "Outcome recorded and merged into MAIN." }], details: {} };
    },
  });

  const loader = new DefaultResourceLoader({
    cwd: root,
    agentDir: getAgentDir(),
    noExtensions: true,
    noSkills: true,
    noPromptTemplates: true,
    noThemes: true,
    noContextFiles: true,
    systemPrompt,
  });
  await loader.reload();
  const { session } = await createAgentSession({
    cwd: root,
    modelRuntime: runtime,
    model,
    thinkingLevel: process.env.PI_REASONING_LEVEL ?? "medium",
    tools: ["bash", "fm_branch_report"],
    customTools: [bashTool, reportTool],
    resourceLoader: loader,
    sessionManager: SessionManager.inMemory(root),
    settingsManager: SettingsManager.inMemory({ retry: { enabled: false } }),
  });
  if (scenario.mirror) {
    await session.sendCustomMessage(
      { role: "custom", customType: "fm-main-mirror", content: scenario.mirror, display: false, timestamp: Date.now() },
      { triggerTurn: false },
    );
  }
  await session.prompt("FIRSTMATE SUPERVISION WAKE: signal: task-lang completed normally");
  session.dispose();

  if (reports.length !== 1) throw new Error(`${scenario.name}: expected exactly one report, got ${reports.length}`);
  const report = reports[0];
  if (report.verdict !== "routine") throw new Error(`${scenario.name}: verdict routing changed to ${report.verdict}`);
  const hasHan = /[\u3400-\u9fff]/u.test(report.summary);
  if (scenario.expected === "zh" && !hasHan) throw new Error(`${scenario.name}: summary is not Chinese: ${report.summary}`);
  if (scenario.expected === "en" && hasHan) throw new Error(`${scenario.name}: summary is not English: ${report.summary}`);
  if (scenario.expected === "es" && !/(complet|pruebas|acción|requiere|bloqueo|necesari|finaliz)/iu.test(report.summary)) {
    throw new Error(`${scenario.name}: summary is not recognizably Spanish: ${report.summary}`);
  }
  if (report.summary.length > 180) throw new Error(`${scenario.name}: summary is not concise (${report.summary.length} chars)`);
  const preferenceRead = bashCalls.some((command) => command.includes("captain.md"));
  if (scenario.requirePreferenceRead && !preferenceRead) {
    throw new Error(`${scenario.name}: model never read the durable captain preference`);
  }

  transcript.scenarios.push({
    name: scenario.name,
    captainMirror: scenario.mirror ?? "(none)",
    durablePreferenceRead: preferenceRead,
    verdict: report.verdict,
    renderedMainNote: `⛵ ${report.task}: ${report.summary}`,
  });
}

const output = process.argv[2];
writeFileSync(output, `${JSON.stringify(transcript, null, 2)}\n`);
console.log(`LIVE_LANGUAGE_OK ${output}`);
