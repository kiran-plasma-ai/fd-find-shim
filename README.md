# find

![shell](https://img.shields.io/badge/bash-%E2%89%A54.4-4EAA25?logo=gnubash&logoColor=white)
![deps](https://img.shields.io/badge/deps-fd%20only-blue)
![license](https://img.shields.io/badge/license-MIT-green)

**Your agents type `find`; this shim makes it `fd` — ~19× faster on large trees, with
all-or-nothing safety: fully translated or verbatim fallback, never a partial translation.**

A drop-in `find` replacement that transparently accelerates the read-only queries that
dominate agent (and human) usage — name/type/mtime/depth/owner searches — by translating
them to [fd](https://github.com/sharkdp/fd). Anything the translation can't express
exactly (`-exec`, `-delete`, `-prune`, OR/NOT expressions, …) is passed to the real
`find` with the original argv untouched, preserving its exit code and stderr.

Measured on this repo's test run: `find /usr -name '*.h'` takes **1519 ms** with GNU find
and **81 ms** through the shim; shim startup overhead is ~9 ms.

## Why all-or-nothing

A translation layer that is *usually* right is a bug farm. Every translation row in
[SPEC.md](SPEC.md) was verified against the reference binaries (GNU findutils 4.11,
fd 10.5), not their `--help` text — including the traps: find ANDs repeated `-type`,
fd ORs them; fd's positional pattern is a regex, not a glob; `-mtime 0` inverts meaning
under fd's windows; fd dedups where find duplicates output. When any of these would
diverge, the shim falls back. `-delete` **always** falls back: accelerating deletions
through a translation layer is risk with no upside.

## Install

```sh
./install.sh                 # installs to ~/.local/bin/find
./install.sh /usr/local/bin  # or anywhere else
```

The installer smoke-tests the shim, warns if `fd` is missing (the shim then passes
everything through), and prints how to handle shells where `find` is an in-process
builtin that never consults PATH (SPEC §6 covers the function-override wrapper it
generates for exactly that case).

## Use

Nothing to learn — call `find` as usual:

```sh
find . -name '*.rs' -type f -mtime -7        # → fd, ~19× faster
find . -name '*.log' -delete                 # → real find, verbatim (destructive)
FIND_WRAP_DEBUG=1 find . -maxdepth 2         # stderr shows which path was taken
FIND_WRAP_OFF=1 find …                       # bypass the shim entirely
```

## Testing

```sh
bash tests/run.sh   # 88 differential tests: shim output vs real find, plus perf probes
```

## Documentation

| File | Contents |
|---|---|
| [SPEC.md](SPEC.md) | Normative spec: every translation row with its verified rationale, fallback rules, deployment tiers, known divergences |

## Scope

Linux, bash ≥ 4.4, fd ≥ 9. Output is not byte-identical to find in the documented
divergences (directory trailing slashes, root inclusion, ordering) — see SPEC §4.6.
The shim never changes what a query *means*; where meaning could shift, it falls back.

## License

[MIT](LICENSE)
