# CI caching for the xnu workflow

`.github/workflows/xnu.yml` uses two caches. Neither can change what the kernel
contains: sources are always re-patched from `xnu/patches`, and every cached
object is keyed on its full input.

## What is cached

1. **Host tools** (`hosttools-cache/hosttools.tgz`, ~0.9 MB): the files `build.sh`
   installs into `dxb/fakeroot` from Apple's `bootstrap_cmds` (mig/migcom),
   `dtrace` (ctfconvert/ctfmerge/ctfdump) and `AvailabilityVersions`
   (availability.pl). The workflow patches its copy of `build.sh` on a miss to write
   `hosttools.list` right after those three steps and before `xnu_headers`, so the
   tarball holds exactly those outputs. On a hit the tarball is unpacked into
   `dxb/fakeroot`; `build.sh` already skips each step when its output exists.
   - Key: `hosttools-<CACHE_VERSION>-<os>-<arch>-<Xcode version>-<DXB_SHA>-<MACOS_VERSION>`
   - Not cached on purpose: `xnu_headers`, libsyscall headers and `libfirehose_kernel`
     (they are generated from / link against the patched xnu), and the xnu source tree.
     `xnu/patches/*` only touch xnu sources, never the three repos above.
2. **ccache** (`.ccache`, max 2 GB, zstd): the XNU kernel C/C++ compiles. xnu's
   `makedefs/MakeInc.def` defines `KCC = $(CCACHE) $(CC)`, so the workflow just sets
   `CCACHE=ccache`. `$(CC)` is left alone because mig uses it. Assembly (`S_KCC`) and
   the link are not cached.
   - Key: `ccache-<CACHE_VERSION>-<os>-<Xcode>-<DXB_SHA>-<MACOS_VERSION>-<KERNEL_CONFIG>-<MACHINE_CONFIG>-<run_id>`
     with `restore-keys` on the same prefix without `run_id`, so a run with changed
     patches restores the newest previous cache and recompiles only changed files.
   - A new entry is saved only when the run had ccache misses (`dirty`), and also when
     the build failed (`-k` runs keep their partial progress).
   - Settings: `CCACHE_COMPILERCHECK=content` (hash the clang binary),
     `CCACHE_SLOPPINESS=include_file_mtime,include_file_ctime` (fresh checkouts have new
     mtimes; contents are still hashed). `time_macros` is not enabled, so files using
     `__DATE__`/`__TIME__` are never served stale. `ccache -s` is printed after the build.
   - `CCACHE_BASEDIR`/`CCACHE_NOHASHDIR` are deliberately unset: base_dir rewrote
     `__FILE__` to `../../../../../xnu/...` in the kernel. The runner workspace path is
     constant, so absolute paths in the hash cost nothing.

## xnu-12377 (26.x): `-MJ` and `tools/xnu-ccache.sh`

xnu-12377's `makedefs/MakeInc.rule` passes `-MJ $(@:o=o.json)` (one compile_commands.json fragment
per object) on every compile, and ccache counts any compile with `-MJ` as an unsupported option.
Run 40828962696 (fork, 2026-10-29): 1180 of 1181 calls uncacheable, a 68 KiB cache saved, so every
26.x build was cold (Build step 18.2 min of the 20.3 min run). `CCACHE` is therefore
`tools/xnu-ccache.sh`: it drops `-MJ`, compiles through ccache and writes the fragment itself, hit or
miss, because `MakeInc.kernel` concatenates the fragments into `compile_commands.json` with `sed`
(a missing one fails the build). ccache's `ignore_options=-MJ*` is not enough: a hit never runs clang,
so it leaves no fragment. The fragment is the command as run (minus `-MJ`), not clang's normalised
one; nothing in the kernel depends on it. Older xnu (no `-MJ`) passes straight through. Checked
locally: with `-MJ` ccache counts `unsupported_compiler_option`; the real 287-word sweet_a630.c
command without it gets as far as the preprocessor, so `-MJ` is the only option ccache refuses.
- Caches are per branch (plus the default branch's), so a fresh `kernel/*` branch per experiment
  always starts cold. Build kernel experiments on one long-lived branch (the b1naryTR fork uses
  `kernel/dev`) so each run restores the previous run's ccache.

## Where a warm 26.x run's minutes go (2026-10-29)

Warm run 40843214529 (11 min, 1178/1180 hits), from the build tree's file times: setup, checkout, `brew install`, cache restore ~1.7 min; up to the xnu source landing ~2 min (dxb cloned xnu and the other Apple repos with full history); source staged and patched by 5.8 min; headers 6.5-6.8; the whole compile 6.9-7.9 (ccache); link + CTF to 8.4; then the error summary (~1.2 min scanning and gzipping a log of hundreds of MB, even after a success), cache save, packaging, upload. Locally, applying our 270 patches takes ~1 s (sequential `git apply --check` + `git apply`) and each patch stage script 1-3 s, so neither is the bottleneck.

Changes: dxb's seven `git clone --branch` become `--depth 1` (dxb only runs `git describe --always` on bootstrap_cmds); dxb's `running` lines carry the time (`⇒ [HH:MM:SS] ...`) and the Build step prints them, so every run's log shows its phases; the error summary only scans the log when the build failed (a success writes empty error files and `gzip -1`s the log).

## Busting caches

- Bump `CACHE_VERSION` in the workflow `env:` (invalidates both caches).
- Changing the Xcode version, `DXB_SHA` or `macos_version` changes the keys automatically.
- Delete a single entry: `gh cache list -R ry-diffusion/Bergamota`, then
  `gh cache delete <id>`.
- Entries for `ci-cache` or other branches are not visible to `main` (and vice versa),
  except that branches can read the default branch's caches.

## Is the kernel the same?

Compared main run 39478166902 (no cache), cold run (1077 misses) and warm run
(1077/1077 hits): same size, same LC_UUID, same symbol table, and every byte outside
the `__CTF` section is identical. `__CTF` (ctfmerge output) differs between any two
builds, cached or not (main vs. a fresh build differs too), so
`SHA256SUMS` is not reproducible across runs with or without ccache.

## Timings (macos-14, Build step; runner speed varies by about +-2 min)

| run | Build step |
|---|---|
| main, no cache (two samples) | 5:06, 7:23 |
| cold (empty caches, 1077 ccache misses) | 8:31 / 5:42 |
| warm (host tools hit, 1077/1077 ccache hits) | 4:43 / 3:22 |

A warm run still pays fixed costs that this change does not cache: KDK download and
install (~1 min), `xnu_headers` (~75 s), libsyscall headers, cloning xnu and the
network-fetching patch stage scripts.
