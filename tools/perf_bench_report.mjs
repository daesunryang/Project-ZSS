#!/usr/bin/env node
import fs from "node:fs";

function readJson(path) {
  return JSON.parse(fs.readFileSync(path, "utf8"));
}

function number(value, digits = 3) {
  return Number(value).toFixed(digits);
}

function safe(value) {
  return String(value).replaceAll("|", "/").replaceAll("\n", " ");
}

function compare(basePath, currentPath) {
  const base = readJson(basePath);
  const current = readJson(currentPath);
  const same = base.digest === current.digest;
  const fields = ["median_ms", "p95_ms", "max_ms"];
  console.log(`[compare] digest ${same ? "MATCH" : "MISMATCH"}`);
  console.log(`[compare] base    ${base.digest}`);
  console.log(`[compare] current ${current.digest}`);
  for (const field of fields) {
    const before = Number(base.tick[field]);
    const after = Number(current.tick[field]);
    const delta = before === 0 ? 0 : ((after - before) / before) * 100;
    console.log(`[compare] tick ${field}: ${number(before)} -> ${number(after)} ms (${delta >= 0 ? "+" : ""}${number(delta, 1)}%)`);
  }
  process.exitCode = same ? 0 : 1;
}

function appendLog(logPath, corePath, clientPath, commit, date) {
  const core = readJson(corePath);
  const client = clientPath && clientPath !== "-" && fs.existsSync(clientPath) ? readJson(clientPath) : null;
  const counts = core.counts;
  const requested = core.requested_counts;
  const countText = `seed ${core.seed}; P${requested.players}/Z${requested.zombies}/I${requested.world_items}; 구조물 ${counts.structures}/보관함 ${counts.containers}`;
  const tick = core.tick;
  const tickText = `${number(tick.median_ms)} / ${number(tick.p95_ms)} / ${number(tick.max_ms)}`;
  const top = core.top_bottlenecks
    .map((entry) => `${entry.name} ${number(entry.median_ms)}/${number(entry.p95_ms)}ms ${number(entry.share_percent, 1)}%`)
    .join("; ");
  let fps = "N/A (미실행)";
  let machine = core.machine;
  if (client) {
    machine += `; ${client.display_driver}; ${client.video_adapter}`;
    fps = client.gpu_measured
      ? `${number(client.fps_average, 2)} / ${number(client.fps_1_percent_low, 2)}`
      : `N/A (headless GPU 미측정; loop ${number(client.fps_average, 2)} / ${number(client.fps_1_percent_low, 2)})`;
  }
  const row = `| ${safe(date)} | ${safe(commit)} | ${safe(machine)} | ${safe(countText)} | ${safe(tickText)} | ${safe(top)} | ${safe(fps)} | ${number(core.achievable_server_tps, 1)} | \`${safe(core.digest)}\` |\n`;
  fs.appendFileSync(logPath, row, "utf8");
  console.log(`[perf] appended ${logPath}`);
}

const [command, ...args] = process.argv.slice(2);
if (command === "compare" && args.length === 2) {
  compare(args[0], args[1]);
} else if (command === "append-log" && args.length === 5) {
  appendLog(args[0], args[1], args[2], args[3], args[4]);
} else {
  console.error("usage: perf_bench_report.mjs compare <base.json> <current.json>");
  console.error("   or: perf_bench_report.mjs append-log <log.md> <core.json> <client.json|-> <commit> <date>");
  process.exitCode = 2;
}
