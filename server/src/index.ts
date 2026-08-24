#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  createReadStream,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import express = require("express");
import type { ErrorRequestHandler, Request, Response } from "express";

const PORT = Number(process.env.PORT || process.env.INTER_ENV_SERVER_PORT || 4010);
const HOST = process.env.HOST || process.env.INTER_ENV_SERVER_HOST || "127.0.0.1";
const DATA_DIR = process.env.INTER_ENV_SERVER_DATA || join(process.cwd(), "data");
const MAX_BYTES = Number(process.env.INTER_ENV_MAX_BYTES || 10 * 1024 * 1024);
const PAIR_TTL_MS = Number(process.env.INTER_ENV_PAIR_TTL_MS || 15 * 60 * 1000);
const SERVER_TOKEN = process.env.INTER_ENV_SERVER_TOKEN || "";

const app = express();

app.use(express.raw({ type: "*/*", limit: MAX_BYTES }));
app.use((req, res, next) => {
  cleanPairFiles();

  if (SERVER_TOKEN && req.header("x-inter-env-token") !== SERVER_TOKEN) {
    res.status(401).type("text/plain").send("unauthorized\n");
    return;
  }

  next();
});

app.get("/health", (_req, res) => {
  res.type("text/plain").send("ok\n");
});

app.put("/v1/accounts/:account/projects/:project/env", (req, res) => {
  const { account, project } = req.params;
  if (!validIds(res, account, project)) return;

  const body = requestBody(req);
  const revision = sha256(body);
  writeFileAtomic(projectFile(account, project), body);
  writeFileAtomic(revisionFile(account, project), Buffer.from(`${revision}\n`));
  res.type("text/plain").send(`${revision}\n`);
});

app.get("/v1/accounts/:account/projects/:project/env", (req, res) => {
  const { account, project } = req.params;
  if (!validIds(res, account, project)) return;

  const file = projectFile(account, project);
  if (!existsSync(file)) {
    res.status(404).type("text/plain").send("not found\n");
    return;
  }

  res.type("application/octet-stream");
  createReadStream(file).pipe(res);
});

app.put("/v1/accounts/:account/projects/:project/devices/:device", (req, res) => {
  const { account, project, device } = req.params;
  if (!validIds(res, account, project, device)) return;

  const revision = requestBody(req).toString("utf8").trim();
  if (!safeId(revision)) {
    res.status(400).type("text/plain").send("invalid revision\n");
    return;
  }

  writeFileAtomic(deviceFile(account, project, device), Buffer.from(`${revision}\n`));
  cleanupSyncedProject(account, project);
  res.status(204).send();
});

app.put("/v1/pair/:pairId", (req, res) => {
  const { pairId } = req.params;
  if (!validIds(res, pairId)) return;

  writeFileAtomic(pairFile(pairId), requestBody(req));
  res.status(204).send();
});

app.get("/v1/pair/:pairId", (req, res) => {
  const { pairId } = req.params;
  if (!validIds(res, pairId)) return;

  const file = pairFile(pairId);
  if (!existsSync(file)) {
    res.status(404).type("text/plain").send("not found\n");
    return;
  }

  const body = readFileSync(file);
  rmSync(file, { force: true });
  res.type("application/octet-stream").send(body);
});

app.use((_req, res) => {
  res.status(404).type("text/plain").send("not found\n");
});

const errorHandler: ErrorRequestHandler = (error, _req, res, _next) => {
  const status = error?.type === "entity.too.large" ? 413 : 500;
  res.status(status).type("text/plain").send(`${error.message || "server error"}\n`);
};
app.use(errorHandler);

function safeId(value: string): boolean {
  return /^[a-f0-9]{8,64}$/.test(value);
}

function validIds(res: Response, ...ids: string[]): boolean {
  if (ids.every(safeId)) return true;

  res.status(400).type("text/plain").send("invalid id\n");
  return false;
}

function requestBody(req: Request): Buffer {
  return Buffer.isBuffer(req.body) ? req.body : Buffer.alloc(0);
}

function writeFileAtomic(file: string, body: Buffer): void {
  mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  writeFileSync(tmp, body, { mode: 0o600 });
  renameSync(tmp, file);
}

function projectDir(account: string, project: string): string {
  return join(DATA_DIR, "accounts", account, "projects", project);
}

function projectFile(account: string, project: string): string {
  return join(projectDir(account, project), "env.bin");
}

function revisionFile(account: string, project: string): string {
  return join(projectDir(account, project), "env.rev");
}

function deviceFile(account: string, project: string, device: string): string {
  return join(projectDir(account, project), "devices", `${device}.rev`);
}

function pairFile(pairId: string): string {
  return join(DATA_DIR, "pairs", `${pairId}.bin`);
}

function sha256(buffer: Buffer): string {
  return createHash("sha256").update(buffer).digest("hex");
}

function cleanPairFiles(): void {
  const dir = join(DATA_DIR, "pairs");
  if (!existsSync(dir)) return;

  const now = Date.now();
  for (const file of readdirSync(dir)) {
    const full = join(dir, file);
    try {
      const stat = statSync(full);
      if (now - stat.mtimeMs > PAIR_TTL_MS) rmSync(full, { force: true });
    } catch {
      // Ignore files concurrently consumed by another request.
    }
  }
}

function cleanupSyncedProject(account: string, project: string): void {
  const env = projectFile(account, project);
  const revisionPath = revisionFile(account, project);
  const devicesPath = join(projectDir(account, project), "devices");
  if (!existsSync(env) || !existsSync(revisionPath) || !existsSync(devicesPath)) return;

  const revision = readFileSync(revisionPath, "utf8").trim();
  const deviceFiles = readdirSync(devicesPath).filter((file) => file.endsWith(".rev"));
  if (deviceFiles.length < 2) return;

  const allSynced = deviceFiles.every((file) => {
    const body = readFileSync(join(devicesPath, file), "utf8").trim();
    return body === revision;
  });

  if (allSynced) rmSync(env, { force: true });
}

mkdirSync(DATA_DIR, { recursive: true, mode: 0o700 });

app.listen(PORT, HOST, () => {
  console.log(`inter-env server listening on http://${HOST}:${PORT}`);
  console.log(`data directory: ${DATA_DIR}`);
});
