import { test } from "bun:test"
import assert from "node:assert/strict"
import { mkdtempSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
import fc from "fast-check"
import { NOTIFICATION_EVENTS, parseDuration, parsePluginConfig, type NotificationEvent } from "../src/config.js"

test("unknown event config keys fail loud instead of falling back to zero-delay defaults", () => {
  assert.throws(
    () =>
      parsePluginConfig(
        JSON.stringify({
          backend: { topic: "test-topic" },
          events: {
            "session.idle ": { notifyAfter: "1m" },
          },
        }),
        "/tmp",
      ),
    /invalid event 'session\.idle '/,
  )
})

test("non-object events config fails loud instead of falling back to zero-delay defaults", () => {
  assert.throws(
    () =>
      parsePluginConfig(
        JSON.stringify({
          backend: { topic: "test-topic" },
          events: ["session.idle", "1m"],
        }),
        "/tmp",
      ),
    /events must be an object/,
  )
})

test("non-object backend template maps fail loud instead of falling back to defaults", () => {
  for (const field of ["title", "message"] as const) {
    assert.throws(
      () =>
        parsePluginConfig(
          JSON.stringify({
            backend: { topic: "test-topic", [field]: ["session.idle", "Agent Idle"] },
          }),
          "/tmp",
        ),
      new RegExp(`backend\\.${field} must be an object`),
    )
  }
})

test("unknown top-level backend and event config keys fail loud", () => {
  assert.throws(
    () => parsePluginConfig(JSON.stringify({ backend: { topic: "test-topic" }, surprise: true }), "/tmp"),
    /unknown key config\.surprise/,
  )
  assert.throws(
    () => parsePluginConfig(JSON.stringify({ backend: { topic: "test-topic", surprise: true } }), "/tmp"),
    /unknown key backend\.surprise/,
  )
  assert.throws(
    () => parsePluginConfig(JSON.stringify({ backend: { topic: "test-topic" }, events: { "session.idle": { surprise: true } } }), "/tmp"),
    /unknown key events\.session\.idle\.surprise/,
  )
})

test("wrong-type known config fields fail loud", () => {
  const cases: Array<[unknown, RegExp]> = [
    [{ enabled: "false", backend: { topic: "test-topic" } }, /enabled must be a boolean/],
    [{ backend: { topic: "test-topic", server: 12 } }, /backend\.server must be a non-empty string/],
    [{ backend: { topic: "test-topic", token: 12 } }, /backend\.token must be a non-empty string/],
    [{ backend: { topic: "test-topic", iconUrl: 12 } }, /backend\.iconUrl must be a non-empty string/],
    [{ backend: { topic: "test-topic", fetchTimeout: 12 } }, /backend\.fetchTimeout must be a non-empty duration string/],
    [{ backend: { topic: "test-topic" }, events: { "session.idle": { enabled: "true" } } }, /events\.session\.idle\.enabled must be a boolean/],
    [{ backend: { topic: "test-topic" }, events: { "session.idle": { notifyAfter: 12 } } }, /events\.session\.idle\.notifyAfter must be a non-empty duration string/],
  ]

  for (const [raw, pattern] of cases) {
    assert.throws(() => parsePluginConfig(JSON.stringify(raw), "/tmp"), pattern)
  }
})

test("missing env and file substitutions fail loud", () => {
  delete process.env.KFACTORY_NTFY_MISSING_TEST_TOKEN
  assert.throws(
    () => parsePluginConfig(JSON.stringify({ backend: { topic: "test-topic", token: "{env:KFACTORY_NTFY_MISSING_TEST_TOKEN}" } }), "/tmp"),
    /env var unset/,
  )
  assert.throws(
    () => parsePluginConfig(JSON.stringify({ backend: { topic: "test-topic", token: "{file:missing-token}" } }), "/tmp"),
    /read failed/,
  )
})

test("disabled config still rejects malformed schema", () => {
  assert.equal(parsePluginConfig(JSON.stringify({ enabled: false }), "/tmp").enabled, false)
  assert.throws(
    () => parsePluginConfig(JSON.stringify({ enabled: false, backend: { topic: "test-topic", server: 12 } }), "/tmp"),
    /backend\.server must be a non-empty string/,
  )
  assert.throws(
    () => parsePluginConfig(JSON.stringify({ enabled: false, events: { "session.idle": { enabled: "true" } } }), "/tmp"),
    /events\.session\.idle\.enabled must be a boolean/,
  )
})

test("valid env and file substitutions still parse", () => {
  const dir = mkdtempSync(join(tmpdir(), "kfactory-ntfy-config-"))
  writeFileSync(join(dir, "token"), "file-token\n")
  process.env.KFACTORY_NTFY_TEST_TOKEN = "env-token"

  const envCfg = parsePluginConfig(JSON.stringify({ backend: { topic: "test-topic", token: "{env:KFACTORY_NTFY_TEST_TOKEN}" } }), dir)
  const fileCfg = parsePluginConfig(JSON.stringify({ backend: { topic: "test-topic", token: "{file:token}" } }), dir)

  assert.equal(envCfg.backend.token, "env-token")
  assert.equal(fileCfg.backend.token, "file-token")
})

test("valid event config keys still parse", () => {
  const cfg = parsePluginConfig(
    JSON.stringify({
      backend: { topic: "test-topic" },
      events: {
        "session.idle": { notifyAfter: "1m" },
        "session.error": { enabled: false, notifyAfter: "2s" },
        "permission.asked": { notifyAfter: "3s" },
      },
    }),
    "/tmp",
  )

  assert.equal(cfg.events["session.idle"].notifyAfterMs, 60_000)
  assert.equal(cfg.events["session.error"].enabled, false)
  assert.equal(cfg.events["session.error"].notifyAfterMs, 2_000)
  assert.equal(cfg.events["permission.asked"].notifyAfterMs, 3_000)
})

test("valid backend template maps still parse", () => {
  const cfg = parsePluginConfig(
    JSON.stringify({
      backend: {
        topic: "test-topic",
        title: {
          "session.idle": { value: "Idle" },
        },
        message: {
          "session.error": { value: "Error" },
        },
      },
    }),
    "/tmp",
  )

  assert.equal(cfg.backend.title?.["session.idle"]?.value, "Idle")
  assert.equal(cfg.backend.message?.["session.error"]?.value, "Error")
})

const unitSeconds = { h: 3600, m: 60, s: 1 } as const
const durationSegmentArb = fc.record({
  value: fc.integer({ min: 0, max: 120 }),
  unit: fc.constantFrom<keyof typeof unitSeconds>("h", "m", "s"),
})

test("property: shorthand durations parse as additive milliseconds", () => {
  fc.assert(
    fc.property(fc.array(durationSegmentArb, { minLength: 1, maxLength: 5 }), (segments) => {
      const input = segments.map((segment) => `${segment.value}${segment.unit}`).join("")
      const expected = segments.reduce((sum, segment) => sum + segment.value * unitSeconds[segment.unit] * 1000, 0)
      assert.equal(parseDuration(input), expected)
    }),
    { numRuns: 100 },
  )
})

test("property: event config accepts exactly the known event keys", () => {
  const eventConfigArb = fc.record({
    enabled: fc.option(fc.boolean(), { nil: undefined }),
    notifyAfter: fc.option(fc.constantFrom("0s", "1s", "2m", "1h30m"), { nil: undefined }),
  })

  fc.assert(
    fc.property(fc.uniqueArray(fc.tuple(fc.constantFrom<NotificationEvent>(...NOTIFICATION_EVENTS), eventConfigArb), { selector: ([key]) => key }), (entries) => {
      const events = Object.fromEntries(entries)
      const cfg = parsePluginConfig(JSON.stringify({ backend: { topic: "test-topic" }, events }), "/tmp")

      for (const key of NOTIFICATION_EVENTS) {
        const raw = events[key]
        assert.equal(cfg.events[key].enabled, typeof raw?.enabled === "boolean" ? raw.enabled : true)
        const expectedNotifyAfter = typeof raw?.notifyAfter === "string" ? parseDuration(raw.notifyAfter) : 0
        assert.equal(cfg.events[key].notifyAfterMs, expectedNotifyAfter)
      }
    }),
    { numRuns: 100 },
  )
})

test("property: unknown event keys always fail loud", () => {
  fc.assert(
    fc.property(
      fc.string({ minLength: 1, maxLength: 16 }).filter((key) => !NOTIFICATION_EVENTS.some((event) => event === key)),
      (key) => {
        const events = Object.create(null) as Record<string, unknown>
        events[key] = { notifyAfter: "1s" }
        assert.throws(
          () => parsePluginConfig(JSON.stringify({ backend: { topic: "test-topic" }, events }), "/tmp"),
          /invalid event/,
        )
      },
    ),
    { numRuns: 100 },
  )
})
