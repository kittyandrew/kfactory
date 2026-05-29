# Re-diffing opencode patches (HARD)
<!-- patches-rediff -- re-diff workflow, hunk-math warning -->

Never hand-edit hunk headers (`@@ -X,Y +A,B @@`). Always re-diff. The
N-way variant below produces ALL kfactory opencode patches in one
pass so the stack stays consistent. `bun-version-relax` is omitted
because it touches a file (`packages/script/src/index.ts`) that no
other patch references -- it can stay as-is during a re-diff.

The stack identity (patch names + order) lives in
`.claude/rules/020-patches.md`; the bumping playbook lives in
`.claude/rules/022-patches-bump.md`.

The trees are STAGES of the stack: each tree has all prior patches
already applied. Diffing adjacent trees yields exactly the patch
between them.

```bash
# 1. Resolve the locked opencode source path
SRC=$(nix shell nixpkgs#jq -c jq -r '.inputs.opencode.path' \
  <(nix flake archive --json))

# 2. Stage one writable copy per stack level (N+1 trees for N
#    re-diffable kfactory patches). The list below MUST match the
#    stack documented in 020-patches.md -- add a new tree when
#    adding a new patch.
WORK=$(mktemp -d -t opencode-patch-XXXX)
TREES=(orig bearer-only workspace-routing full)
for d in "''${TREES[@]}"; do
  cp -r "$SRC" "$WORK/$d"
done
chmod -R u+w "$WORK"

# 3. Apply current patches progressively (each tree gets all
#    upstream-of-it patches stacked).
nix shell nixpkgs#patch -c bash -c "
  set -e
  cd $WORK/bearer-only                  && patch -p1 < $PWD/patches/opencode-static-bearer.patch

  cd $WORK/workspace-routing            && patch -p1 < $PWD/patches/opencode-static-bearer.patch
  cd $WORK/workspace-routing            && patch -p1 < $PWD/patches/opencode-workspace-routing.patch

  cd $WORK/full                         && patch -p1 < $PWD/patches/opencode-static-bearer.patch
  cd $WORK/full                         && patch -p1 < $PWD/patches/opencode-workspace-routing.patch
  cd $WORK/full                         && patch -p1 < $PWD/patches/opencode-kfactory-refresh.patch
"

# 4. Make your edits to the appropriate tree (changes ALWAYS mirror
#    into every tree downstream of the one you edit):
#      $WORK/bearer-only/...                  -- static-bearer changes
#                                                also copy into workspace-routing and full
#      $WORK/workspace-routing/...            -- workspace-routing changes
#                                                also copy into full
#      $WORK/full/...                         -- kfactory-refresh changes

# 5. Re-diff one pass per adjacent-tree pair (N pairs for N patches).
nix shell nixpkgs#git -c bash -c "
  git diff --no-index $WORK/orig                       $WORK/bearer-only                  > /tmp/patch1.raw
  git diff --no-index $WORK/bearer-only                $WORK/workspace-routing            > /tmp/patch2.raw
  git diff --no-index $WORK/workspace-routing          $WORK/full                         > /tmp/patch3.raw
"
# Strip the absolute-path prefixes that `git diff --no-index` writes.
sed -i -e "s|a$WORK/orig/|a/|g"                       -e "s|b$WORK/bearer-only/|b/|g"                  /tmp/patch1.raw
sed -i -e "s|a$WORK/bearer-only/|a/|g"                -e "s|b$WORK/workspace-routing/|b/|g"            /tmp/patch2.raw
sed -i -e "s|a$WORK/workspace-routing/|a/|g"          -e "s|b$WORK/full/|b/|g"                         /tmp/patch3.raw

# 6. Preserve the leading explanation headers (the prose before each
#    patch's first `diff --git`) and concat with the new diff bodies.
#    The patches list MUST be the same set + order as the diff pairs
#    above.
PATCHES=(opencode-static-bearer opencode-workspace-routing opencode-kfactory-refresh)
for name in "''${PATCHES[@]}"; do
  patch=patches/$name.patch
  diff_line=$(grep -n "^diff --git" "$patch" | head -1 | cut -d: -f1)
  header_lines=$((diff_line - 1))
  head -n $header_lines "$patch" > "/tmp/$name.header"
done
cat /tmp/opencode-static-bearer.header       /tmp/patch1.raw > patches/opencode-static-bearer.patch
cat /tmp/opencode-workspace-routing.header   /tmp/patch2.raw > patches/opencode-workspace-routing.patch
cat /tmp/opencode-kfactory-refresh.header    /tmp/patch3.raw > patches/opencode-kfactory-refresh.patch

# 7. Verify
nix flake check
rm -rf "$WORK"
```

When adding a NEW patch to the stack, four places update together:
the `TREES=` array, the progressive-apply block in step 3, the
diff-pairs in step 5, and the `PATCHES=` list + concat lines in step
6. Skipping any of those four guarantees a broken regenerate. Also
extend the stack identity in `020-patches.md` to match.

## Hunk math you must NEVER touch by hand

The header `@@ -X,Y +A,B @@` encodes line offsets and counts. Adding
lines to the `+` body without updating `B` (or `Y` after removals)
silently desyncs the patch -- `patch -p1` will reject loudly or apply
a wrong hunk silently. The re-diff workflow regenerates these headers
from scratch every time. Do not hand-edit them.
