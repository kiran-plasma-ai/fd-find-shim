#!/usr/bin/env bash
# tests/run.sh — SPEC.md §7 suite: dispatch, safety, parity, recursion, benchmark.
#
# SAFETY RULE (learned the hard way — an earlier version of this suite ran a
# real-find fallback with `-delete` in the project dir and deleted it):
# anything that reaches the REAL find runs in a scratch cwd with a read-only
# predicate. Destructive predicates are only tested against the stub.
set -u
cd "$(dirname "$0")/.."
SHIM=$PWD/find-shim
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }

# --- stubs: record argv, announce which one ran -------------------------------
mkdir -p "$T/bin"
cat >"$T/bin/fd-stub" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then echo "fd ${FAKE_FD_VERSION:-10.5.0}"; exit 0; fi
printf '%s\n' "$@" >"$STUB_LOG.fd"
echo FD-CALLED
EOF
cat >"$T/bin/find-stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_LOG.find"
echo FIND-CALLED
EOF
chmod +x "$T/bin/fd-stub" "$T/bin/find-stub"

# shim_env <extra env assignments...> -- runs shim with stub binaries,
# scrubbing FIND_WRAP_* vars inherited from the caller's environment
shim_env() {
	env -u FIND_WRAP_MODE -u FIND_WRAP_OFF -u FIND_WRAP_DEBUG \
		STUB_LOG="$T/log" FIND_WRAP_FD="$T/bin/fd-stub" \
		FIND_WRAP_REAL_FIND="$T/bin/find-stub" "$@"
}

# run_shim <args...> → WHO (fd|find|???), ARGV (newline-joined stub argv)
run_shim() {
	rm -f "$T/log.fd" "$T/log.find"
	local out
	out=$(shim_env "$SHIM" "$@" 2>/dev/null)
	case $out in
	FD-CALLED) WHO=fd ;;
	FIND-CALLED) WHO=find ;;
	*) WHO="???" ;;
	esac
	ARGV=""
	[[ -f $T/log.fd ]] && ARGV=$(cat "$T/log.fd")
	[[ -f $T/log.find ]] && ARGV=$(cat "$T/log.find")
}

# E <args...> → newline-joined expectation (trailing newline stripped by $())
E() { printf '%s\n' "$@"; }

P=(--hidden --no-ignore --color=never) # parity-flag prefix

expect_who() { # <desc> <fd|find> <shim args...>
	local desc=$1 want=$2
	shift 2
	run_shim "$@"
	if [[ $WHO == "$want" ]]; then ok; else bad "$desc: wanted $want, got $WHO"; fi
}

expect_fd() { # <desc> <expected argv...> -- <shim args...>
	local desc=$1
	shift
	local -a want=()
	while [[ $1 != -- ]]; do want+=("$1"); shift; done
	shift
	run_shim "$@"
	local wantj
	wantj=$(E "${want[@]}")
	if [[ $WHO == fd && $ARGV == "$wantj" ]]; then ok; else
		bad "$desc: wanted fd argv [$(echo "${want[*]}")], got $WHO [$(echo "${ARGV//$'\n'/ }")]"
	fi
}

echo "== dispatch: translated invocations =="
expect_fd "bare path" "${P[@]}" '' . -- .
expect_fd "-name glob gets -g -s" "${P[@]}" -g -s '*.txt' . -- . -name '*.txt'
expect_fd "-iname gets -g -i" "${P[@]}" -g -i readme . -- . -iname readme
expect_fd "-type f" "${P[@]}" -t f '' . -- . -type f
expect_fd "-type d + -maxdepth" "${P[@]}" -t d -d 2 '' . -- . -type d -maxdepth 2
expect_fd "multiple roots" "${P[@]}" '' src docs -- src docs
expect_fd "-L follows" "${P[@]}" -L '' . -- -L .
expect_fd "-L then -P: last wins, no -L" "${P[@]}" '' . -- -L -P .
expect_fd "-P then -L: last wins, -L" "${P[@]}" -L '' . -- -P -L .
expect_fd "-H -P accepted" "${P[@]}" '' . -- -H -P .
expect_fd "-empty" "${P[@]}" -t e '' . -- . -empty
expect_fd "-mindepth" "${P[@]}" --min-depth 2 '' . -- . -mindepth 2
expect_fd "-mtime -1" "${P[@]}" --changed-within 1d '' . -- . -mtime -1
expect_fd "-mtime +2" "${P[@]}" --changed-before 2d '' . -- . -mtime +2
expect_fd "-mmin -30" "${P[@]}" --changed-within 30m '' . -- . -mmin -30
expect_fd "-user" "${P[@]}" -o root '' . -- . -user root
expect_fd "-group" "${P[@]}" -o :wheel '' . -- . -group wheel
expect_fd "-print0" "${P[@]}" -0 '' . -- . -print0
expect_fd "-print dropped" "${P[@]}" '' . -- . -print
expect_fd "combined" "${P[@]}" -t f -d 3 -g -s '*.py' . -- . -name '*.py' -type f -maxdepth 3

echo "== dispatch: environment switches =="
rm -f "$T/log.fd"
shim_env FIND_WRAP_MODE=fast "$SHIM" . >/dev/null 2>&1
ARGV=$(cat "$T/log.fd" 2>/dev/null || true)
[[ $ARGV == $'\n.' ]] && ok || bad "fast mode drops parity flags: [$(echo "${ARGV//$'\n'/ }")]"

out=$(shim_env FIND_WRAP_OFF=1 "$SHIM" . 2>/dev/null)
[[ $out == FIND-CALLED ]] && ok || bad "FIND_WRAP_OFF=1 falls back: $out"

out=$(env STUB_LOG="$T/log" FIND_WRAP_FD=/nonexistent/fd \
	FIND_WRAP_REAL_FIND="$T/bin/find-stub" "$SHIM" . 2>/dev/null)
[[ $out == FIND-CALLED ]] && ok || bad "missing fd falls back: $out"

out=$(env STUB_LOG="$T/log" FAKE_FD_VERSION=8.9.0 FIND_WRAP_FD="$T/bin/fd-stub" \
	FIND_WRAP_REAL_FIND="$T/bin/find-stub" "$SHIM" . 2>/dev/null)
[[ $out == FIND-CALLED ]] && ok || bad "fd < 9 falls back: $out"

echo "== dispatch: fallbacks reach real find with identical argv =="
expect_who "-delete" find . -delete
expect_who "-exec" find . -exec rm {} \;
expect_who "-prune" find . -name x -prune
expect_who "-o" find . -name a -o -name b
expect_who "! negation" find . '!' -name a
expect_who "-size demoted" find . -size +100k
expect_who "-path demoted" find . -path './src/*'
expect_who "-regex demoted" find . -regex '.*py'
expect_who "-newer demoted" find . -newer /etc/hostname
expect_who "exact -mtime demoted" find . -mtime 3
expect_who "double -name demoted" find . -name a -name b
expect_who "double -type demoted" find . -type f -type d
expect_who "-name with slash demoted" find . -name 'a/b'
expect_who "-name empty demoted" find . -name ''
expect_who "bare find" find
expect_who "options only" find -L
expect_who "--version passthrough" find --version
expect_who "missing -name arg" find . -name
expect_who "non-numeric -maxdepth" find . -maxdepth x
expect_who "out-of-range -maxdepth" find . -maxdepth 99999999999999999999999
# review regressions (each was a shipped mistranslation)
expect_who "-executable demoted" find . -executable
expect_who "-name dash-leading glob" find . -name -type
expect_who "-name dash-star glob" find . -name '-*'
expect_who "-mtime 0" find . -mtime -0
expect_who "-mtime +0" find . -mtime +0
expect_who "-mmin -0" find . -mmin -0
expect_who "mixed -mtime -mmin" find . -mtime +1 -mmin +30
expect_who "mixed -mmin -mtime" find . -mmin -30 -mtime -1
expect_who "-user empty" find . -user ''
expect_who "-user with colon" find . -user node:node
expect_who "-user dash-leading" find . -user -name
expect_who "-group empty" find . -group ''
expect_who "repeated -print0" find . -print0 -print0
expect_who "-print then -print0" find . -print -print0

run_shim . -name a -o -name b
[[ $WHO == find && $ARGV == "$(E . -name a -o -name b)" ]] \
	&& ok || bad "fallback argv byte-identical: [$(echo "${ARGV//$'\n'/ }")]"

echo "== recursion guard (scratch cwd, read-only predicate) =="
cp "$SHIM" "$T/bin/find"
out=$(cd "$T" && env STUB_LOG="$T/log" PATH="$T/bin:/usr/bin:/bin" \
	FIND_WRAP_FD="$T/bin/fd-stub" FIND_WRAP_REAL_FIND="$T/bin/find" \
	FIND_WRAP_DEBUG=1 "$T/bin/find" . -false 2>&1)
rc=$?
# FIND_WRAP_REAL_FIND points at the shim itself: the guard must reject it and
# land on /usr/bin/find (never loop into the shim). `-false` is read-only;
# real find must actually run and exit 0.
case $out in
*'fallback -> /usr/bin/find'*) [[ $rc == 0 ]] && ok || bad "recursion guard: rc=$rc" ;;
*) bad "recursion guard: $out" ;;
esac

echo "== parity against real binaries (scratch cwd) =="
REALFIND=/usr/bin/find
REALFD=/usr/bin/fd
if [[ -x $REALFIND && -x $REALFD ]]; then
	FX="$T/fix"
	mkdir -p "$FX/src/deep" "$FX/.hidden"
	touch "$FX/README" "$FX/readme.txt" "$FX/src/main.py" "$FX/emptyfile" \
		"$FX/.hidden/secret" "$FX/ignored.txt" "$FX/with space.txt" "$FX/ünïcode.txt"
	truncate -s 0 "$FX/src/deep/zero"
	ln -s src "$FX/dirlink"
	ln -s README "$FX/filelink"
	ln -s nowhere "$FX/broken"
	printf 'ignored.txt\n' >"$FX/.gitignore"
	git -C "$FX" init -q .
	touch -d '2 hours ago' "$FX/recent.txt"
	# -size rounding trap fixtures (guards any future v2 size mapping)
	truncate -s 102400 "$FX/exact100k"
	truncate -s 102399 "$FX/under100k"

	# parity_run <desc> <find args...>: shim (real fd) vs GNU find,
	# sorted, directory trailing slashes normalized. Read-only predicates only.
	# fd never prints the search root itself (SPEC §4.6 accepted divergence):
	# strip root-operand lines from find's output before comparing.
	parity_run() {
		local desc=$1
		shift
		local -a roots=()
		local a
		for a in "$@"; do
			case $a in
			-*) break ;;
			*) roots+=("$a") ;;
			esac
		done
		local want got
		want=$("$REALFIND" "$@" 2>/dev/null | sed 's:/$::' | sort)
		local r
		for r in "${roots[@]}"; do want=$(printf '%s\n' "$want" | grep -Fxv -- "$r"); done
		got=$("$SHIM" "$@" 2>/dev/null | sed 's:/$::' | sort)
		if [[ $want == "$got" ]]; then ok; else
			printf 'FAIL: parity %s\n--- find ---\n%s\n--- shim ---\n%s\n' "$desc" "$want" "$got" >&2
			fail=$((fail + 1))
		fi
	}

	cd "$FX" || exit 1
	parity_run "match-all" .
	parity_run "-name case-sensitive miss" . -name readme
	parity_run "-name case-sensitive hit" . -name README
	parity_run "-name glob" . -name '*.txt'
	parity_run "-iname" . -iname 'readme*'
	parity_run "-name with space" . -name 'with space.txt'
	parity_run "-name unicode" . -name 'ünïcode.txt'
	parity_run "hidden file" . -name secret
	parity_run "gitignored file" . -name ignored.txt
	parity_run "-type f" . -type f
	parity_run "-type d" . -type d
	parity_run "-type l" . -type l
	parity_run "-L -type l" -L . -type l
	parity_run "-empty" . -empty
	parity_run "-maxdepth 1" . -maxdepth 1
	parity_run "-mindepth 2" . -mindepth 2
	parity_run "-mtime -1" . -mtime -1
	parity_run "-mmin -30" . -mmin -30
	parity_run "multi-root" src .hidden -type f
	parity_run "-user self" . -user "$(id -un)" -maxdepth 1
	parity_run "-group self" . -group "$(id -gn)" -maxdepth 1

	# symlink search roots (dispatch, against the real fixture tree)
	expect_who "dir-symlink root falls back" find dirlink
	expect_who "file-symlink root falls back" find filelink
	expect_who "-L file-symlink root falls back" find -L filelink
	expect_fd "-H dir-symlink root ok" "${P[@]}" '' dirlink -- -H dirlink
	expect_fd "-L dir-symlink root ok" "${P[@]}" -L '' dirlink -- -L dirlink

	want=$("$REALFIND" . -type f -print0 | tr '\0' '\n' | sort)
	got=$("$SHIM" . -type f -print0 | tr '\0' '\n' | sort)
	[[ $want == "$got" ]] && ok || bad "parity -print0"

	# real-find fallback, read-only predicate, scratch cwd
	got=$(FIND_WRAP_DEBUG=1 "$SHIM" . -false 2>&1 >/dev/null)
	case $got in
	*'fallback -> /usr/bin/find'*) ok ;;
	*) bad "fallback to real find: $got" ;;
	esac
	cd - >/dev/null || exit 1
else
	echo "SKIP: parity tests (need /usr/bin/find and /usr/bin/fd)"
fi

echo "== benchmark (informational) =="
if [[ -x /usr/bin/fd ]] && (( BASH_VERSINFO[0] >= 5 )); then
	ms() { # ms <cmd...> → wall time in ms
		local t0=$EPOCHREALTIME
		"$@" >/dev/null 2>&1
		awk -v a="$t0" -v b="$EPOCHREALTIME" 'BEGIN{printf "%.0f", (b-a)*1000}'
	}
	echo "  find /usr -name '*.h':     $(ms "$REALFIND" /usr -name '*.h')ms"
	echo "  shim (via fd):             $(ms "$SHIM" /usr -name '*.h')ms"
	echo "  shim startup (maxdepth 0): $(ms "$SHIM" . -maxdepth 0)ms"
fi

echo
echo "passed: $pass  failed: $fail"
(( fail == 0 ))
