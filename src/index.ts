#!/usr/bin/env node

import { createHash, timingSafeEqual } from "node:crypto";
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
const HOST = process.env.HOST || process.env.INTER_ENV_SERVER_HOST || "0.0.0.0";
const DATA_DIR = process.env.INTER_ENV_SERVER_DATA || join(process.cwd(), "data");
const MAX_BYTES = Number(process.env.INTER_ENV_MAX_BYTES || 10 * 1024 * 1024);
const PAIR_TTL_MS = Number(process.env.INTER_ENV_PAIR_TTL_MS || 15 * 60 * 1000);
const SERVER_TOKEN = process.env.INTER_ENV_SERVER_TOKEN || "";

const app = express();

app.get("/", (_req, res) => {
  res.type("text/plain").send(
    [
      "inter-env",
      "",
      "Encrypted .env sync across machines.",
      "",
      "Setup: interenv setup",
      "Sync a repo: interenv init",
      "Install: curl -fsSL https://interenv.bytode.dev/install.sh | sh",
      "Health: /health",
      "API: /v1",
      "",
      "GitHub: https://github.com/marvinified/interenv",
      "Bytode: https://bytode.dev",
      "",
    ].join("\n"),
  );
});

app.get("/install.sh", (_req, res) => {
  res.type("text/x-shellscript").sendFile(join(__dirname, "install.sh"));
});

app.get("/interenv", (_req, res) => {
  res.type("text/x-shellscript").sendFile(join(__dirname, "interenv"));
});

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

app.put("/v1/accounts/:account", (req, res) => {
  const { account } = req.params;
  if (!validIds(res, account)) return;
  if (existsSync(accountRevokedFile(account))) {
    res.status(410).type("text/plain").send("account deleted\n");
    return;
  }

  const verifier = requestBody(req).toString("utf8").trim();
  if (!/^[a-f0-9]{64}$/.test(verifier)) {
    res.status(400).type("text/plain").send("invalid deletion verifier\n");
    return;
  }

  const file = accountDeleteVerifierFile(account);
  if (existsSync(file)) {
    const existing = readFileSync(file, "utf8").trim();
    if (!sameSecret(existing, verifier)) {
      res.status(409).type("text/plain").send("account already registered\n");
      return;
    }
  } else {
    writeFileAtomic(file, Buffer.from(`${verifier}\n`));
  }

  res.status(204).send();
});

app.delete("/v1/accounts/:account", (req, res) => {
  const { account } = req.params;
  if (!validIds(res, account)) return;

  if (existsSync(accountRevokedFile(account))) {
    res.status(204).send();
    return;
  }

  const verifierFile = accountDeleteVerifierFile(account);
  const deletionSecret = requestBody(req).toString("utf8").trim();
  if (!existsSync(verifierFile) || !deletionSecret) {
    res.status(401).type("text/plain").send("invalid deletion secret\n");
    return;
  }

  const expected = readFileSync(verifierFile, "utf8").trim();
  const supplied = sha256(Buffer.from(deletionSecret));
  if (!sameSecret(expected, supplied)) {
    res.status(401).type("text/plain").send("invalid deletion secret\n");
    return;
  }

  writeFileAtomic(accountRevokedFile(account), Buffer.alloc(0));
  rmSync(accountDir(account), { recursive: true, force: true });
  res.status(204).send();
});

app.use("/v1/accounts/:account/projects", (req, res, next) => {
  const { account } = req.params;
  if (!validIds(res, account)) return;
  if (existsSync(accountRevokedFile(account))) {
    res.status(410).type("text/plain").send("account deleted\n");
    return;
  }
  next();
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
  if (!validPairCode(res, pairId)) return;

  if (!writePairFileOnce(pairId, requestBody(req))) {
    res.status(409).type("text/plain").send("pairing code already active\n");
    return;
  }
  res.status(204).send();
});

app.get("/v1/pair/:pairId", (req, res) => {
  const { pairId } = req.params;
  if (!validPairCode(res, pairId)) return;

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

function validPairCode(res: Response, code: string): boolean {
  if (/^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$/.test(code)) return true;

  res.status(400).type("text/plain").send("invalid pairing code\n");
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

function writePairFileOnce(pairId: string, body: Buffer): boolean {
  const file = pairFile(pairId);
  mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
  try {
    writeFileSync(file, body, { flag: "wx", mode: 0o600 });
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") return false;
    throw error;
  }
}

function projectDir(account: string, project: string): string {
  return join(accountDir(account), "projects", project);
}

function accountDir(account: string): string {
  return join(DATA_DIR, "accounts", account);
}

function accountDeleteVerifierFile(account: string): string {
  return join(accountDir(account), "delete.sha256");
}

function accountRevokedFile(account: string): string {
  return join(DATA_DIR, "revoked", account);
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

function sameSecret(left: string, right: string): boolean {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);
  return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
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
