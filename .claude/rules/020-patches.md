# Editing the opencode patches
<!-- .claude/rules/020-patches.md -- re-diff workflow, hunk math, flake checks -->

Two opencode patches are line-number-pinned against the
`inputs.opencode` flake input (the exact tag pinned in `flake.nix`):

- `patches/opencode-bearer-and-routing.patch` -- upstreamable subset:
  bearer flag, `--workspace` plumbing, workspace-routing header
  fallback, post-`adapter.create` project re-resolve.
- `patches/opencode-kfactory-refresh.patch` -- kfactory-specific glue,
  applied on top: cache file, subprocess refresh, schema-versioned
  auth.json read, toast subscription.

Editing either by hand is fragile because every addition or removal
shifts hunk offsets; the safe path is to **always re-diff against a
fresh opencode source**.

`patches/oauth2-proxy-pkce-no-secret.patch` is verbatim
[oauth2-proxy#3168](https://github.com/oauth2-proxy/oauth2-proxy/pull/3168);
typically untouched.

## Picking which patch to edit

A change is in the bearer-and-routing patch if it's something opencode
upstream would plausibly accept: env-var flag wiring, CLI flags on
`opencode attach`, workspace-id plumbing, header-routing semantics,
project re-resolve after adapter.create.

A change is in the kfactory-refresh patch if it's kfactory-specific:
anything touching `OPENCODE_SERVER_BEARER_CACHE_PATH`,
`createBearerRefreshFetch`, `spawnKfactoryRefresh`, `AuthFile`,
`KFACTORY_EXIT_*`, the `onBearerRefreshHint` toast bus.

When in doubt: edit the refresh patch. Keeping the bearer-and-routing
patch clean of kfactory specifics is what makes it upstreamable.

## Re-diff workflow (HARD)

Never hand-edit hunk headers (`@@ -X,Y +A,B @@`). Always re-diff. The
three-way variant below produces BOTH patches in one pass so the split
stays consistent.

```bash
# 1. Resolve the locked opencode source path
SRC=$(nix shell nixpkgs#jq -c jq -r '.inputs.opencode.path' \
  <(nix flake archive --json))

# 2. Stage three writable copies (orig + upstream-only + full)
WORK=$(mktemp -d -t opencode-patch-XXXX)
cp -r "$SRC" "$WORK/orig"
cp -r "$SRC" "$WORK/upstream"
cp -r "$SRC" "$WORK/full"
chmod -R u+w "$WORK/orig" "$WORK/upstream" "$WORK/full"

# 3. Apply current patches to BOTH `upstream` and `full`. Apply only
#    the bearer-and-routing patch to `upstream`. Apply both to `full`.
(cd "$WORK/upstream" && patch -p1 < patches/opencode-bearer-and-routing.patch)
(cd "$WORK/full"     && patch -p1 < patches/opencode-bearer-and-routing.patch)
(cd "$WORK/full"     && patch -p1 < patches/opencode-kfactory-refresh.patch)

# 4. Make your edits:
#      $WORK/upstream/...  -- ONLY upstreamable changes (also mirror
#                             them into $WORK/full so the second patch
#                             continues to apply cleanly).
#      $WORK/full/...      -- kfactory-specific changes only here.

# 5. Re-diff. Patch1 = orig -> upstream. Patch2 = upstream -> full.
nix shell nixpkgs#git -c git diff --no-index "$WORK/orig" "$WORK/upstream" \
  > /tmp/patch1.raw
sed -i -e "s|a$WORK/orig/|a/|g" -e "s|b$WORK/upstream/|b/|g" /tmp/patch1.raw
nix shell nixpkgs#git -c git diff --no-index "$WORK/upstream" "$WORK/full" \
  > /tmp/patch2.raw
sed -i -e "s|a$WORK/upstream/|a/|g" -e "s|b$WORK/full/|b/|g" /tmp/patch2.raw

# 6. Preserve the leading explanation headers (the prose before each
#    patch's first `diff --git`) and concat with the new diff bodies.
for name in opencode-bearer-and-routing opencode-kfactory-refresh; do
  patch=patches/$name.patch
  diff_line=$(grep -n "^diff --git" "$patch" | head -1 | cut -d: -f1)
  header_lines=$((diff_line - 1))
  head -n $header_lines "$patch" > "/tmp/$name.header"
done
cat /tmp/opencode-bearer-and-routing.header /tmp/patch1.raw \
  > patches/opencode-bearer-and-routing.patch
cat /tmp/opencode-kfactory-refresh.header /tmp/patch2.raw \
  > patches/opencode-kfactory-refresh.patch

# 7. Verify
nix flake check
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
4. The plugin typecheck uses the published `@opencode-ai/plugin` types,
   not the source, so it's independent of this bump.
5. `factory-opencode-typecheck` catches type-semantic drift in either
   patch against the bumped source.

## What to verify on every edit

- `nix flake check` -- in particular both patches must pass
  `factory-opencode-patch-applies` AND the resulting tree must pass
  `factory-opencode-typecheck`.
- For changes to the subprocess-refresh logic in `attach.ts`: verify
  the spawned binary name still matches the binary you ship (today:
  `spawn("kfactory", ["auth", "refresh"])`) and that the exit-code
  constants stay in sync with `cmd/kfactory/exit.go`.
