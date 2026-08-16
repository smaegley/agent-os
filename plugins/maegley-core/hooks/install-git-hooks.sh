#!/usr/bin/env bash
# install-git-hooks.sh <repo-path> — wire secret-scan.sh in as a pre-commit hook.
#
# Idempotent. Preserves an existing pre-commit hook by chaining to it.

set -euo pipefail

REPO="${1:?usage: install-git-hooks.sh <repo-path>}"
SCANNER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secret-scan.sh"

[ -d "$REPO/.git" ] || { echo "not a git repo: $REPO" >&2; exit 1; }
chmod +x "$SCANNER"

HOOK="$REPO/.git/hooks/pre-commit"

if [ -f "$HOOK" ] && grep -q "secret-scan.sh" "$HOOK"; then
  echo "already installed: $HOOK"
  exit 0
fi

if [ -f "$HOOK" ]; then
  mv "$HOOK" "$HOOK.local"
  echo "preserved existing hook as pre-commit.local (will still run)"
fi

cat > "$HOOK" <<EOF
#!/usr/bin/env bash
# Installed by maegley-core. Do not edit; edit secret-scan.sh instead.
[ -x "\$(dirname "\$0")/pre-commit.local" ] && "\$(dirname "\$0")/pre-commit.local" || true
exec "$SCANNER" --staged
EOF

chmod +x "$HOOK"
echo "installed: $HOOK -> $SCANNER"
