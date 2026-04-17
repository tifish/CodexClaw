import test from "node:test";
import assert from "node:assert/strict";
import {
  formatStartupError,
  isTelegramPollingConflict
} from "../src/lib/startup.js";

test("detects Telegram polling conflicts from Telegraf-style errors", () => {
  const error = {
    code: 409,
    description:
      "Conflict: terminated by other getUpdates request; make sure that only one bot instance is running"
  };

  assert.equal(isTelegramPollingConflict(error), true);
});

test("does not misclassify unrelated Telegram API errors as polling conflicts", () => {
  const error = {
    response: {
      error_code: 401,
      description: "Unauthorized"
    }
  };

  assert.equal(isTelegramPollingConflict(error), false);
});

test("formats Telegram polling conflicts with an actionable startup message", () => {
  const error = {
    response: {
      error_code: 409,
      description:
        "Conflict: terminated by other getUpdates request; make sure that only one bot instance is running"
    }
  };

  assert.match(
    formatStartupError(error),
    /another bot instance is already calling/
  );
  assert.match(formatStartupError(error), /retry `npm run start`/);
});

test("falls back to the shared error formatter for generic startup failures", () => {
  assert.equal(formatStartupError(new Error("boom")), "boom");
});
