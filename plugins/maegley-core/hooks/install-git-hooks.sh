#!/usr/bin/env bash
# install-git-hooks.sh <repo-path> — wire the maegley-core pre-commit checks
# (secret-scan.sh + validate-frontmatter.sh) in as a pre-commit hook.
#
# WR-023 / ADR-0013 adds the front-matter validator alongside the existing secret
# scanner. Both run on every commit, each reports its own findings in one pass, and
# the commit is refused only if either is in `block` mode and finds something.
#
# Idempotent. Preserves a genuinely foreign pre-commit hook by chaining to it as
# pre-commit.local. A prior maegley-core hook (scanner-only, pre-WR-023) is upgraded
# in place — it is our generated file, not a user hook.

set -euo pipefail

REPO="${1:?usage: install-git-hooks.sh <repo-path>}"
HOOKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$HOOKDIR/secret-scan.sh"
VALIDATOR="$HOOKDIR/validate-frontmatter.sh"

[ -d "$REPO/.git" ] || { echo "not a git repo: $REPO" >&2; exit 1; }
chmod +x "$SCANNER" "$VALIDATOR"

HOOK="$REPO/.git/hooks/pre-commit"

# Fully wired already (both checks present) — nothing to do.
if [ -f "$HOOK" ] && grep -q "secret-scan.sh" "$HOOK" && grep -q "validate-frontmatter.sh" "$HOOK"; then
  echo "already installed (both checks): $HOOK"
  exit 0
fi

# A hook that is NOT ours (no secret-scan.sh marker) is a user hook — preserve + chain it.
# A hook that IS ours but stale (scanner only) is regenerated in place below, NOT chained to
# itself (that would double-run the scanner).
if [ -f "$HOOK" ] && ! grep -q "secret-scan.sh" "$HOOK"; then
  mv "$HOOK" "$HOOK.local"
  echo "preserved existing hook as pre-commit.local (will still run)"
fi

cat > "$HOOK" <<EOF
#!/usr/bin/env bash
# Installed by maegley-core. Do not edit; edit the hook scripts instead.
[ -x "\$(dirname "\$0")/pre-commit.local" ] && "\$(dirname "\$0")/pre-commit.local" || true
rc=0
"$SCANNER"   --staged || rc=\$?
"$VALIDATOR" --staged || rc=\$?
exit \$rc
EOF

chmod +x "$HOOK"
echo "installed: $HOOK -> secret-scan.sh + validate-frontmatter.sh"
