# Editing the opencode patches
<!-- patches -- five-patch stack, re-diff workflow, picking which patch -->

Five opencode patches are line-number-pinned against the
`inputs.opencode` flake input (the exact tag pinned in `flake.nix`).
Stack order is mandatory:

0. `patches/opencode-bun-version-relax.patch` -- **TEMPORARY**.
   Single-file (`packages/script/src/index.ts`) one-line change
   relaxing the bun-version range from `^${packageManager}` to
   `>=1.3.13` so nixpkgs's bun 1.3.13 can build opencode v1.15.5+.
   Drop when nixpkgs#519796 (bun 1.3.13 -> 1.3.14) merges. Lives at
   the top of the stack because it touches a file none of the other
   patches do; ordering doesn't actually matter for this one but it
   stays first by convention to keep the "drop me later" intent
   visible.
1. `patches/opencode-bearer-and-routing.patch` -- upstreamable subset:
   bearer flag, `--workspace` plumbing, workspace-routing header
   fallback (v1 + v2 path), `Session.list` + `Session.listGlobal`
   workspaceID filter (workspace_id supersedes project_id when set),
   plugin-adapter ProjectID.global registration.
2. `patches/opencode-workspace-branch.patch` -- upstreamable subset:
   `WorkspaceHttpApi.list` enriches each row's `branch` field with a
   FRESH `.git/HEAD` read at request time (via Effect.forEach +
   Effect.sync, concurrency unbounded). Independent file
   (handlers/workspace.ts) -- neither neighbour patch touches it.
3. `patches/opencode-session-subscribers.patch` -- publishes
   `kfactory.subscribers.changed` bus events on every SSE attach /
   detach to BOTH the per-instance `/event` AND the front-opencode
   `/global/event` (shared WeakMap exported from handlers/event.ts,
   imported by handlers/global.ts). Used by `plugins/ntfy` to skip /
   cancel notifications when an operator is attached.
4. `patches/opencode-kfactory-refresh.patch` -- kfactory-specific glue,
   applied on top: cache file, subprocess refresh, schema-versioned
   auth.json read, toast subscription. Line-pinned against patches
   1-3's post-apply hashes.

`patches/oauth2-proxy-pkce-no-secret.patch` is verbatim
[oauth2-proxy#3168](https://github.com/oauth2-proxy/oauth2-proxy/pull/3168);
typically untouched.

Editing any opencode patch by hand is fragile because every addition or
removal shifts hunk offsets; the safe path is to **always re-diff
against a fresh opencode source**.

## Picking which patch to edit

A change is in **bearer-and-routing** if it's something opencode upstream
would plausibly accept: env-var flag wiring, CLI flags on
`opencode attach`, workspace-id plumbing, header-routing semantics,
session.list filtering by workspace_id, plugin-adapter project scope.

A change is in **workspace-branch** if it touches
`WorkspaceHttpApi.list` row enrichment (today: live `branch` read
from `.git/HEAD`). Adding e.g. `dirty: bool` or `head: <sha>` to
list rows would belong here. Independent file; safe to edit in
isolation.

A change is in **session-subscribers** if it's about exposing SSE
subscriber lifecycle to plugins (the `kfactory.subscribers.changed`
event + the shared WeakMap counter that handlers/event.ts owns and
handlers/global.ts imports). Adding more plugin surface area for
"what's the server doing" signals belongs here.

A change is in **kfactory-refresh** if it's kfactory-specific: anything
touching `OPENCODE_SERVER_BEARER_CACHE_PATH`, `createBearerRefreshFetch`,
`spawnKfactoryRefresh`, `AuthFile`, `KFACTORY_EXIT_*`, the
`onBearerRefreshHint` toast bus.

When in doubt: edit the refresh patch. Keeping the upstreamable
patches (bearer-and-routing, workspace-branch, session-subscribers)
clean of kfactory specifics is what makes them upstreamable.

## Re-diff workflow (HARD)

Never hand-edit hunk headers (`@@ -X,Y +A,B @@`). Always re-diff. The
N-way variant below produces ALL kfactory opencode patches in one
pass so the stack stays consistent. `bun-version-relax` is omitted
because it touches a file (`packages/script/src/index.ts`) that no
other patch references -- it can stay as-is during a re-diff.

The trees are STAGES of the stack: each tree has all prior patches
already applied. Diffing adjacent trees yields exactly the patch
between them.

```bash
# 1. Resolve the locked opencode source path
SRC=$(nix shell nixpkgs#jq -c jq -r '.inputs.opencode.path' \
  <(nix flake archive --json))

# 2. Stage one writable copy per stack level (N+1 trees for N
#    re-diffable kfactory patches). The list below MUST match the
#    stack documented at the top of this file -- add a new tree
#    when adding a new patch.
WORK=$(mktemp -d -t opencode-patch-XXXX)
TREES=(orig bearer-only bearer-plus-branch bearer-plus-branch-plus-sub full)
for d in "''${TREES[@]}"; do
  cp -r "$SRC" "$WORK/$d"
done
chmod -R u+w "$WORK"

# 3. Apply current patches progressively (each tree gets all
#    upstream-of-it patches stacked).
nix shell nixpkgs#patch -c bash -c "
  set -e
  cd $WORK/bearer-only                  && patch -p1 < $PWD/patches/opencode-bearer-and-routing.patch

  cd $WORK/bearer-plus-branch           && patch -p1 < $PWD/patches/opencode-bearer-and-routing.patch
  cd $WORK/bearer-plus-branch           && patch -p1 < $PWD/patches/opencode-workspace-branch.patch

  cd $WORK/bearer-plus-branch-plus-sub  && patch -p1 < $PWD/patches/opencode-bearer-and-routing.patch
  cd $WORK/bearer-plus-branch-plus-sub  && patch -p1 < $PWD/patches/opencode-workspace-branch.patch
  cd $WORK/bearer-plus-branch-plus-sub  && patch -p1 < $PWD/patches/opencode-session-subscribers.patch

  cd $WORK/full                         && patch -p1 < $PWD/patches/opencode-bearer-and-routing.patch
  cd $WORK/full                         && patch -p1 < $PWD/patches/opencode-workspace-branch.patch
  cd $WORK/full                         && patch -p1 < $PWD/patches/opencode-session-subscribers.patch
  cd $WORK/full                         && patch -p1 < $PWD/patches/opencode-kfactory-refresh.patch
"

# 4. Make your edits to the appropriate tree (changes ALWAYS mirror
#    into every tree downstream of the one you edit):
#      $WORK/bearer-only/...                  -- bearer-and-routing changes
#                                                also copy into bearer-plus-branch,
#                                                bearer-plus-branch-plus-sub, full
#      $WORK/bearer-plus-branch/...           -- workspace-branch changes
#                                                also copy into bearer-plus-branch-plus-sub, full
#      $WORK/bearer-plus-branch-plus-sub/...  -- session-subscribers changes
#                                                also copy into full
#      $WORK/full/...                         -- kfactory-refresh changes

# 5. Re-diff one pass per adjacent-tree pair (N pairs for N patches).
nix shell nixpkgs#git -c bash -c "
  git diff --no-index $WORK/orig                       $WORK/bearer-only                  > /tmp/patch1.raw
  git diff --no-index $WORK/bearer-only                $WORK/bearer-plus-branch           > /tmp/patch2.raw
  git diff --no-index $WORK/bearer-plus-branch         $WORK/bearer-plus-branch-plus-sub  > /tmp/patch3.raw
  git diff --no-index $WORK/bearer-plus-branch-plus-sub $WORK/full                        > /tmp/patch4.raw
"
# Strip the absolute-path prefixes that `git diff --no-index` writes.
sed -i -e "s|a$WORK/orig/|a/|g"                       -e "s|b$WORK/bearer-only/|b/|g"                  /tmp/patch1.raw
sed -i -e "s|a$WORK/bearer-only/|a/|g"                -e "s|b$WORK/bearer-plus-branch/|b/|g"           /tmp/patch2.raw
sed -i -e "s|a$WORK/bearer-plus-branch/|a/|g"         -e "s|b$WORK/bearer-plus-branch-plus-sub/|b/|g"  /tmp/patch3.raw
sed -i -e "s|a$WORK/bearer-plus-branch-plus-sub/|a/|g" -e "s|b$WORK/full/|b/|g"                        /tmp/patch4.raw

# 6. Preserve the leading explanation headers (the prose before each
#    patch's first `diff --git`) and concat with the new diff bodies.
#    The patches list MUST be the same set + order as the diff pairs
#    above.
PATCHES=(opencode-bearer-and-routing opencode-workspace-branch opencode-session-subscribers opencode-kfactory-refresh)
for name in "''${PATCHES[@]}"; do
  patch=patches/$name.patch
  diff_line=$(grep -n "^diff --git" "$patch" | head -1 | cut -d: -f1)
  header_lines=$((diff_line - 1))
  head -n $header_lines "$patch" > "/tmp/$name.header"
done
cat /tmp/opencode-bearer-and-routing.header  /tmp/patch1.raw > patches/opencode-bearer-and-routing.patch
cat /tmp/opencode-workspace-branch.header    /tmp/patch2.raw > patches/opencode-workspace-branch.patch
cat /tmp/opencode-session-subscribers.header /tmp/patch3.raw > patches/opencode-session-subscribers.patch
cat /tmp/opencode-kfactory-refresh.header    /tmp/patch4.raw > patches/opencode-kfactory-refresh.patch

# 7. Verify
nix flake check
rm -rf "$WORK"
```

When adding a NEW patch to the stack, three places update together:
the `TREES=` array, the progressive-apply block in step 3, the
diff-pairs in step 5, and the `PATCHES=` list + concat lines in step
6. Skipping any of those four guarantees a broken regenerate.

## Hunk math you must NEVER touch by hand

The header `@@ -X,Y +A,B @@` encodes line offsets and counts. Adding
lines to the `+` body without updating `B` (or `Y` after removals)
silently desyncs the patch -- `patch -p1` will reject loudly or apply
a wrong hunk silently. The re-diff workflow regenerates these headers
from scratch every time. Do not hand-edit them.

## Bumping the opencode pin

1. Edit `flake.nix`'s `inputs.opencode.url` to the new tag.
2. `nix flake update opencode` to refresh the lock.
3. `nix flake check`. If `factory-opencode-patch-applies` fails, the
   patches' line numbers drifted -- re-diff per the workflow above.
4. The plugin typechecks use the published `@opencode-ai/plugin` types,
   not the source, so they're independent of this bump.
5. `factory-opencode-typecheck` catches type-semantic drift across any
   of the kfactory opencode patches against the bumped source.

## What to verify on every edit

- `nix flake check` -- in particular the kfactory opencode patches
  must all pass `factory-opencode-patch-applies` AND the resulting
  tree must pass `factory-opencode-typecheck`.
- For changes to the subprocess-refresh logic in `attach.ts`: verify
  the spawned binary name still matches the binary you ship (today:
  `spawn("kfactory", ["auth", "refresh"])`) and that the exit-code
  constants stay in sync with `cmd/kfactory/exit.go`.
- For changes to session-subscribers' event.ts: verify
  `plugins/ntfy/src/index.ts` still references the `kfactory.subscribers.changed`
  event name verbatim. The plugin treats unknown event names as no-ops
  (fail-open), so a rename would silently disable skip-on-connect.
