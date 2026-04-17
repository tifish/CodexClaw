import { toErrorMessage } from "./errors.js";

interface TelegramErrorLike {
  code?: unknown;
  description?: unknown;
  response?: {
    error_code?: unknown;
    description?: unknown;
  };
}

function readTelegramErrorCode(error: TelegramErrorLike): number | null {
  if (typeof error.code === "number") {
    return error.code;
  }

  if (typeof error.response?.error_code === "number") {
    return error.response.error_code;
  }

  return null;
}

function readTelegramErrorDescription(error: TelegramErrorLike): string {
  if (typeof error.description === "string") {
    return error.description;
  }

  if (typeof error.response?.description === "string") {
    return error.response.description;
  }

  return "";
}

export function isTelegramPollingConflict(error: unknown): boolean {
  if (!error || typeof error !== "object") {
    return false;
  }

  const telegramError = error as TelegramErrorLike;
  const code = readTelegramErrorCode(telegramError);
  const description = readTelegramErrorDescription(telegramError);

  return (
    code === 409 && /terminated by other getupdates request/i.test(description)
  );
}

export function formatStartupError(error: unknown): string {
  if (isTelegramPollingConflict(error)) {
    return [
      "Telegram polling conflict: another bot instance is already calling",
      "`getUpdates` for this bot token. Stop the other process or switch that",
      "deployment to webhook mode, then retry `npm run start`."
    ].join(" ");
  }

  return toErrorMessage(error);
}
