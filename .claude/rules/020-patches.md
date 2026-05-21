# Editing the opencode patches
<!-- patches -- three-patch stack, four-way re-diff, picking which patch -->

Three opencode patches are line-number-pinned against the
`inputs.opencode` flake input (the exact tag pinned in `flake.nix`).
Stack order is mandatory:

1. `patches/opencode-bearer-and-routing.patch` -- upstreamable subset:
   bearer flag, `--workspace` plumbing, workspace-routing header
   fallback, post-`adapter.create` project re-resolve.
2. `patches/opencode-session-subscribers.patch` -- publishes
   `kfactory.subscribers.changed` bus events on every SSE attach /
   detach. Used by `plugins/ntfy` to skip / cancel notifications when
   an operator is attached. Independent file (event.ts) -- neither
   neighbour patch touches it, so stacking is mechanical, not
   line-pinned.
3. `patches/opencode-kfactory-refresh.patch` -- kfactory-specific glue,
   applied on top: cache file, subprocess refresh, schema-versioned
   auth.json read, toast subscription. Line-pinned against #1's
   post-apply hashes; #2 doesn't shift any of the files #3 touches.

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
project re-resolve after adapter.create.

A change is in **session-subscribers** if it's about exposing SSE
subscriber lifecycle to plugins (currently just the
`kfactory.subscribers.changed` event in event.ts). Adding more plugin
surface area for "what's the server doing" type signals belongs here.

A change is in **kfactory-refresh** if it's kfactory-specific: anything
touching `OPENCODE_SERVER_BEARER_CACHE_PATH`, `createBearerRefreshFetch`,
`spawnKfactoryRefresh`, `AuthFile`, `KFACTORY_EXIT_*`, the
`onBearerRefreshHint` toast bus.

When in doubt: edit the refresh patch. Keeping the bearer-and-routing
patch clean of kfactory specifics is what makes it upstreamable.

## Re-diff workflow (HARD)

Never hand-edit hunk headers (`@@ -X,Y +A,B @@`). Always re-diff. The
four-way variant below produces ALL THREE patches in one pass so the
stack stays consistent.

```bash
# 1. Resolve the locked opencode source path
SRC=$(nix shell nixpkgs#jq -c jq -r '.inputs.opencode.path' \
  <(nix flake archive --json))

# 2. Stage four writable copies, one per stack level
WORK=$(mktemp -d -t opencode-patch-XXXX)
for d in orig bearer-only bearer-plus-sub full; do
  cp -r "$SRC" "$WORK/$d"
done
chmod -R u+w "$WORK"/{orig,bearer-only,bearer-plus-sub,full}

# 3. Apply current patches progressively
nix shell nixpkgs#patch -c bash -c "
  cd $WORK/bearer-only      && patch -p1 < $PWD/patches/opencode-bearer-and-routing.patch
  cd $WORK/bearer-plus-sub  && patch -p1 < $PWD/patches/opencode-bearer-and-routing.patch
  cd $WORK/bearer-plus-sub  && patch -p1 < $PWD/patches/opencode-session-subscribers.patch
  cd $WORK/full             && patch -p1 < $PWD/patches/opencode-bearer-and-routing.patch
  cd $WORK/full             && patch -p1 < $PWD/patches/opencode-session-subscribers.patch
  cd $WORK/full             && patch -p1 < $PWD/patches/opencode-kfactory-refresh.patch
"

# 4. Make your edits to the appropriate tree:
#      $WORK/bearer-only/...       -- bearer-and-routing changes only
#                                     (also mirror into bearer-plus-sub + full)
#      $WORK/bearer-plus-sub/...   -- session-subscribers changes only
#                                     (also mirror into full)
#      $WORK/full/...              -- kfactory-refresh changes only

# 5. Re-diff in three passes.
nix shell nixpkgs#git -c bash -c "
  git diff --no-index $WORK/orig            $WORK/bearer-only     > /tmp/patch1.raw
  git diff --no-index $WORK/bearer-only     $WORK/bearer-plus-sub > /tmp/patch2.raw
  git diff --no-index $WORK/bearer-plus-sub $WORK/full            > /tmp/patch3.raw
"
sed -i -e "s|a$WORK/orig/|a/|g"            -e "s|b$WORK/bearer-only/|b/|g"     /tmp/patch1.raw
sed -i -e "s|a$WORK/bearer-only/|a/|g"     -e "s|b$WORK/bearer-plus-sub/|b/|g" /tmp/patch2.raw
sed -i -e "s|a$WORK/bearer-plus-sub/|a/|g" -e "s|b$WORK/full/|b/|g"            /tmp/patch3.raw

# 6. Preserve the leading explanation headers (the prose before each
#    patch's first `diff --git`) and concat with the new diff bodies.
for name in opencode-bearer-and-routing opencode-session-subscribers opencode-kfactory-refresh; do
  patch=patches/$name.patch
  diff_line=$(grep -n "^diff --git" "$patch" | head -1 | cut -d: -f1)
  header_lines=$((diff_line - 1))
  head -n $header_lines "$patch" > "/tmp/$name.header"
done
cat /tmp/opencode-bearer-and-routing.header  /tmp/patch1.raw > patches/opencode-bearer-and-routing.patch
cat /tmp/opencode-session-subscribers.header /tmp/patch2.raw > patches/opencode-session-subscribers.patch
cat /tmp/opencode-kfactory-refresh.header    /tmp/patch3.raw > patches/opencode-kfactory-refresh.patch

# 7. Verify
nix flake check
rm -rf "$WORK"
```

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
   of the three patches against the bumped source.

## What to verify on every edit

- `nix flake check` -- in particular all three patches must pass
  `factory-opencode-patch-applies` AND the resulting tree must pass
  `factory-opencode-typecheck`.
- For changes to the subprocess-refresh logic in `attach.ts`: verify
  the spawned binary name still matches the binary you ship (today:
  `spawn("kfactory", ["auth", "refresh"])`) and that the exit-code
  constants stay in sync with `cmd/kfactory/exit.go`.
- For changes to session-subscribers' event.ts: verify
  `plugins/ntfy/src/index.ts` still references the `kfactory.subscribers.changed`
  event name verbatim. The plugin treats unknown event names as no-ops
  (fail-open), so a rename would silently disable skip-on-connect.
