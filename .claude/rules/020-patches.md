# Editing opencode-bearer-auth.patch
<!-- .claude/rules/020-patches.md -- re-diff workflow, hunk math, flake checks -->

`patches/opencode-bearer-auth.patch` is line-number-pinned against the
`inputs.opencode` flake input (the exact tag pinned in `flake.nix`).
Editing it by hand is fragile because every addition or removal shifts
hunk offsets; the safe path is to **always re-diff against a fresh
opencode source**.

`patches/oauth2-proxy-pkce-no-secret.patch` is verbatim
[oauth2-proxy#3168](https://github.com/oauth2-proxy/oauth2-proxy/pull/3168);
typically untouched.

## Re-diff workflow (HARD)

Never hand-edit hunk headers (`@@ -X,Y +A,B @@`). Always:

```bash
# 1. Resolve the locked opencode source path
SRC=$(nix shell nixpkgs#jq -c jq -r '.inputs.opencode.path' \
  <(nix flake archive --json))

# 2. Stage two writable copies (orig + edit) in /tmp
WORK=$(mktemp -d -t opencode-patch-XXXX)
cp -r "$SRC" "$WORK/orig"
cp -r "$SRC" "$WORK/edit"
chmod -R u+w "$WORK/orig" "$WORK/edit"

# 3. Apply the current patch to the edit copy
(cd "$WORK/edit" && patch -p1 < patches/opencode-bearer-auth.patch)

# 4. Make edits in $WORK/edit/... (Read/Edit tools or $EDITOR)

# 5. Re-diff orig vs edit; rewrite the absolute paths to a/ b/
nix shell nixpkgs#git -c git diff --no-index "$WORK/orig" "$WORK/edit" \
  > /tmp/new-patch.raw
sed -i -e "s|a$WORK/orig/|a/|g" -e "s|b$WORK/edit/|b/|g" /tmp/new-patch.raw

# 6. Preserve the leading explanation header (the ~38 lines before the
#    first `diff --git`) and concat with the new diff body.
head -n 38 patches/opencode-bearer-auth.patch > /tmp/header.txt
cat /tmp/header.txt /tmp/new-patch.raw > patches/opencode-bearer-auth.patch

# 7. Verify
nix flake check
```

## Hunk math you must NEVER touch by hand

The header `@@ -X,Y +A,B @@` encodes line offsets and counts. Adding
lines to the `+` body without updating `B` (or `Y` after removals)
silently desyncs the patch -- `patch -p1` will reject loudly or apply a
wrong hunk silently. The re-diff workflow regenerates these headers
from scratch every time. Do not hand-edit them.

## Bumping the opencode pin

1. Edit `flake.nix`'s `inputs.opencode.url` to the new tag.
2. `nix flake update opencode` to refresh the lock.
3. `nix flake check`. If `factory-opencode-patch-applies` fails, the
   patch's line numbers drifted -- re-diff per the workflow above.
4. The plugin typecheck uses the published `@opencode-ai/plugin` types,
   not the source, so it's independent of this bump.
5. Type-semantic drift in the patch (not just line numbers) is NOT
   caught by the flake check. Manually verify: cd into the opencode
   source, apply the patch, `bun install`, `bun turbo typecheck`.

## What to verify on every edit

- `nix flake check` -- both `factory-opencode-patch-applies` and
  `factory-plugin-typecheck` must pass.
- For changes to the subprocess-refresh logic in `attach.ts`: verify
  the spawned binary name still matches the binary you ship (today:
  `spawn("kfactory", ["auth", "refresh"])`).
