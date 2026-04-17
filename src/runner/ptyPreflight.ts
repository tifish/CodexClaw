import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { toErrorMessage } from "../lib/errors.js";

const EXECUTE_MASK = 0o111;

export interface ExecutablePermissionResult {
  path: string;
  changed: boolean;
  executable: boolean;
  error?: string;
}

interface NativePtyModule {
  dir: string;
}

interface NodePtyUtilsModule {
  loadNativeModule(name: string): NativePtyModule;
}

export function requiresNodePtySpawnHelper(
  platform: NodeJS.Platform = process.platform
): boolean {
  return platform !== "win32";
}

export function ensureExecutablePermissions(
  filePath: string
): ExecutablePermissionResult {
  const stat = fs.statSync(filePath);
  const executable = Boolean(stat.mode & EXECUTE_MASK);
  if (executable) {
    return {
      path: filePath,
      changed: false,
      executable: true
    };
  }

  fs.chmodSync(filePath, stat.mode | EXECUTE_MASK);
  const verified = Boolean(fs.statSync(filePath).mode & EXECUTE_MASK);
  return {
    path: filePath,
    changed: true,
    executable: verified
  };
}

export function resolveNodePtySpawnHelperPath(
  platform: NodeJS.Platform = process.platform
): string {
  if (!requiresNodePtySpawnHelper(platform)) {
    return "";
  }

  const require = createRequire(import.meta.url);
  const unixTerminalPath = require.resolve("node-pty/lib/unixTerminal.js");
  const unixTerminalDir = path.dirname(unixTerminalPath);
  const utils = require("node-pty/lib/utils") as NodePtyUtilsModule;
  const native = utils.loadNativeModule("pty");

  return path.resolve(unixTerminalDir, native.dir, "spawn-helper");
}

export function repairNodePtySpawnHelperPermissions(
  platform: NodeJS.Platform = process.platform
): ExecutablePermissionResult {
  if (!requiresNodePtySpawnHelper(platform)) {
    return {
      path: `Not required on ${platform}`,
      changed: false,
      executable: true
    };
  }

  try {
    const helperPath = resolveNodePtySpawnHelperPath(platform);
    return ensureExecutablePermissions(helperPath);
  } catch (error: unknown) {
    return {
      path: "",
      changed: false,
      executable: false,
      error: toErrorMessage(error)
    };
  }
}
