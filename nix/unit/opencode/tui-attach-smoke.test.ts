import { expect, test } from "bun:test"
import { mkdir, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"

type SeenRequest = {
  method: string
  path: string
  search: string
  workspace?: string
  authorization?: string
}

type RunningProcess = {
  child: ReturnType<typeof Bun.spawn>
  stdout: Promise<string>
  stderr: Promise<string>
  kill(): Promise<void>
}

const sourceDir = path.resolve(import.meta.dir, "../../")
const indexPath = path.join(sourceDir, "src/index.ts")

function minimalConfigPath(home: string) {
  return path.join(home, ".config/opencode/minimal.jsonc")
}

function envFor(home: string, extra?: Record<string, string | undefined>) {
  return {
    ...process.env,
    HOME: home,
    XDG_CONFIG_HOME: path.join(home, ".config"),
    XDG_DATA_HOME: path.join(home, ".local/share"),
    XDG_STATE_HOME: path.join(home, ".local/state"),
    XDG_CACHE_HOME: path.join(home, ".cache"),
    OPENCODE_EXPERIMENTAL_WORKSPACES: "true",
    OPENCODE_CONFIG: minimalConfigPath(home),
    OPENCODE_DISABLE_PROJECT_CONFIG: "1",
    OPENCODE_DISABLE_AUTOUPDATE: "1",
    OPENCODE_DISABLE_AUTOCOMPACT: "1",
    OPENCODE_DISABLE_MODELS_FETCH: "1",
    TERM: "xterm-256color",
    ...extra,
  }
}

async function waitFor(label: string, fn: () => boolean | Promise<boolean>, timeoutMs = 60_000) {
  const started = Date.now()
  while (!(await fn())) {
    if (Date.now() - started > timeoutMs) throw new Error(`timed out waiting for ${label}`)
    await Bun.sleep(100)
  }
}

function allocatePort() {
  const server = Bun.serve({ port: 0, fetch: () => new Response("ok") })
  const port = server.port
  server.stop(true)
  return port
}

async function makeHome(prefix: string) {
  const home = path.join(tmpdir(), `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2)}`)
  await mkdir(home, { recursive: true })
  await mkdir(path.dirname(minimalConfigPath(home)), { recursive: true })
  await writeFile(minimalConfigPath(home), JSON.stringify({ share: "disabled", autoupdate: false, autocompact: false }))
  return home
}

async function createGitRepo(root: string) {
  const repo = path.join(root, "repo")
  await mkdir(repo, { recursive: true })
  await run(["git", "init"], repo)
  await run(["git", "config", "user.email", "test@example.invalid"], repo)
  await run(["git", "config", "user.name", "Test User"], repo)
  await writeFile(path.join(repo, "README.md"), "# test repo\n")
  await run(["git", "add", "README.md"], repo)
  await run(["git", "commit", "-m", "initial"], repo)
  return repo
}

async function run(args: string[], cwd: string) {
  const proc = Bun.spawn(args, { cwd, stdout: "pipe", stderr: "pipe" })
  const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited])
  if (code !== 0) throw new Error(`${args.join(" ")} failed (${code})\nstdout:\n${stdout}\nstderr:\n${stderr}`)
  return stdout
}

function spawnProcess(args: string[], options: Parameters<typeof Bun.spawn>[1]): RunningProcess {
  const child = Bun.spawn(args, { ...options, stdout: "pipe", stderr: "pipe" })
  return {
    child,
    stdout: new Response(child.stdout).text(),
    stderr: new Response(child.stderr).text(),
    async kill() {
      child.kill()
      await child.exited.catch(() => undefined)
    },
  }
}

async function startOpencodeServe(home: string, repo: string) {
  const port = allocatePort()
  const proc = spawnProcess(
    ["bun", "run", "--conditions=browser", indexPath, "serve", "--hostname", "127.0.0.1", "--port", String(port)],
    { cwd: repo, env: envFor(home) },
  )
  const url = `http://127.0.0.1:${port}`
  await Bun.sleep(1_000)
  return { url, proc }
}

function startRecordingProxy(upstream: string, seen: SeenRequest[]) {
  return Bun.serve({
    port: 0,
    async fetch(req) {
      const incoming = new URL(req.url)
      seen.push({
        method: req.method,
        path: incoming.pathname,
        search: incoming.search,
        workspace: req.headers.get("x-opencode-workspace") ?? incoming.searchParams.get("workspace") ?? undefined,
        authorization: req.headers.get("authorization") ?? undefined,
      })
      const target = new URL(incoming.pathname + incoming.search, upstream)
      const headers = new Headers(req.headers)
      headers.delete("host")
      return fetch(target, {
        method: req.method,
        headers,
        body: req.method === "GET" || req.method === "HEAD" ? undefined : req.body,
      })
    },
  })
}

function spawnAttach(url: string, workspaceID: string, home: string, extraEnv?: Record<string, string | undefined>) {
  const command = [
    "bun",
    "run",
    "--conditions=browser",
    indexPath,
    "attach",
    url,
    "--workspace",
    workspaceID,
    "--continue",
  ].join(" ")
  return spawnProcess(["script", "-q", "-e", "-c", command, "/dev/null"], { cwd: sourceDir, env: envFor(home, extraEnv) })
}

async function writeAuthFile(authPath: string, token: string, expiresAt: Date) {
  await mkdir(path.dirname(authPath), { recursive: true })
  await writeFile(
    authPath,
    JSON.stringify({ schema_version: 1, access_token: token, refresh_token: "refresh-token", expires_at: expiresAt.toISOString() }),
  )
}

async function withRealAttach(
  label: string,
  fn: (ctx: { serverUrl: string; proxyUrl: string; seen: SeenRequest[]; workspaceID: string; root: string }) => Promise<void>,
) {
  const root = await makeHome(`opencode-tui-${label}`)
  const serverHome = path.join(root, "server-home")
  const repo = await createGitRepo(root)
  const seen: SeenRequest[] = []
  const serve = await startOpencodeServe(serverHome, repo)
  const proxy = startRecordingProxy(serve.url, seen)
  const workspaceID = "wrk_attachsmoke"
  try {
    await fn({ serverUrl: serve.url, proxyUrl: `http://127.0.0.1:${proxy.port}`, seen, workspaceID, root })
  } catch (error) {
    console.error("seen requests:", JSON.stringify(seen, null, 2))
    await serve.proc.kill()
    console.error("serve stdout:", await serve.proc.stdout.catch((err) => String(err)))
    console.error("serve stderr:", await serve.proc.stderr.catch((err) => String(err)))
    throw error
  } finally {
    proxy.stop(true)
    await serve.proc.kill()
    await rm(root, { recursive: true, force: true })
  }
}

test("opencode attach talks to real serve with workspace-scoped requests", async () => {
  await withRealAttach("real-bootstrap", async ({ proxyUrl, seen, workspaceID, root }) => {
    const clientHome = path.join(root, "client-home")
    const child = spawnAttach(proxyUrl, workspaceID, clientHome, { OPENCODE_SERVER_BEARER: "test-token" })
    try {
      // POST /sync/start arrives with x-opencode-workspace as a HEADER
      // (empty query: the SDK only rewrites header -> query for GET/HEAD),
      // so this asserts the non-GET header-fallback middleware end to end.
      // GET /session?workspace= is the --continue session-list scoping.
      // (The /global/event SSE stream is not asserted: under the headless
      // `script` PTY the v1.17.4 TUI tears the stream down on stdin EOF
      // before the proxy can observe it; /sync/start fires from the same
      // post-event-subscription code path in packages/tui/src/context/sdk.tsx.)
      await waitFor("workspace-scoped real TUI bootstrap requests", () =>
        seen.some((r) => r.method === "POST" && r.path === "/sync/start" && r.search === "" && r.workspace === workspaceID) &&
        seen.some((r) => r.method === "GET" && r.path === "/session" && r.workspace === workspaceID),
      )
      expect(seen.some((r) => r.authorization === "Bearer test-token")).toBe(true)
    } catch (error) {
      console.error("pty stdout:", await child.stdout.catch((err) => String(err)))
      console.error("pty stderr:", await child.stderr.catch((err) => String(err)))
      throw error
    } finally {
      await child.kill()
    }
  })
}, 120_000)

test("opencode attach reads fresh bearer from shared auth cache", async () => {
  await withRealAttach("fresh-cache", async ({ proxyUrl, seen, workspaceID, root }) => {
    const clientHome = path.join(root, "client-home")
    const authPath = path.join(root, "auth.json")
    await writeAuthFile(authPath, "fresh-token", new Date("2999-01-01T00:00:00.000Z"))
    const child = spawnAttach(proxyUrl, workspaceID, clientHome, { OPENCODE_SERVER_BEARER_CACHE_PATH: authPath })
    try {
      await waitFor("fresh cache bearer", () => seen.some((r) => r.authorization === "Bearer fresh-token"))
    } catch (error) {
      console.error("pty stdout:", await child.stdout.catch((err) => String(err)))
      console.error("pty stderr:", await child.stderr.catch((err) => String(err)))
      throw error
    } finally {
      await child.kill()
    }
  })
}, 120_000)
