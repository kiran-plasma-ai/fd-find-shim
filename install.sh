#!/usr/bin/env bash
# install.sh — install the find shim per SPEC.md §6.
set -euo pipefail
cd "$(dirname "$0")"

dest=${1:-$HOME/.local/bin}
sharedir=$dest/../share/find-shim
install -Dm755 find-shim "$dest/find"

# Generate the function override with the ACTUAL install path baked in —
# a static file would break for non-default dest.
install -dm755 "$sharedir"
cat >"$sharedir/find-wrapper.sh" <<EOF
# find-wrapper.sh — source this in shells where \`find\` is shadowed by an
# in-process builtin ahead of PATH (e.g. omp's bash tool). A shell function
# takes precedence over those builtins; a PATH shim alone does not.
find() { "$dest/find" "\$@"; }
EOF

echo "installed: $dest/find"
echo "wrapper:   $sharedir/find-wrapper.sh"
echo

# Install-time verification (SPEC §6 tier 3).
if ! { [[ -x /usr/bin/fd ]] || [[ -x /usr/bin/fdfind ]] || command -v fd >/dev/null; }; then
	echo "WARNING: no fd found — the shim will pass everything through to real find."
fi
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
probe=$(cd "$scratch" && FIND_WRAP_DEBUG=1 "$dest/find" . -maxdepth 1 2>&1 || true)
case $probe in
*'fd ->'*) echo "smoke test: shim translates via fd ✓" ;;
*'fallback ->'*) echo "smoke test: shim falls back to real find (fd unusable?):"; echo "  $probe" ;;
*) echo "WARNING: smoke test produced unexpected output:"; echo "  $probe" ;;
esac

# Tier 1: PATH shim — only works if $dest precedes /usr/bin in PATH.
case :$PATH: in
*":$dest:"*) ;;
*)
	echo
	echo "NOTE: $dest is not in PATH (or not before /usr/bin)."
	echo "      Add it in front of /usr/bin for the shim to take effect."
	;;
esac

cat <<EOF

If your agent shell resolves \`find\` as a builtin ('type find' says
"shell builtin"), PATH is never consulted. Note (SPEC §6): omp's builtin
find is already fast — override only if you want fd semantics there.
  a) Surgical: source $sharedir/find-wrapper.sh in that shell's init.
  b) Blunt (omp): PI_DISABLE_UUTILS_BUILTINS=1 before launch — removes ALL
     in-process utility builtins, not just find.

Verify in each target shell:
  type find                              # must show the shim or the function
  FIND_WRAP_DEBUG=1 find . -maxdepth 0   # stderr shows the fd translation
EOF
