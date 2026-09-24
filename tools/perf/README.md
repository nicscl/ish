# Performance harness

Tools for measuring where the macOS command-line build of iSH spends its time, and for comparing the asbestos engine with the experimental Unicorn engine (`emu/unicorn.c`). Results and conclusions are in [FINDINGS.md](FINDINGS.md).

## Builds

```sh
# asbestos only, optimized, with symbols for the profiler
meson setup ../ish-prof --buildtype=release -Db_ndebug=true -Dc_args='-g -fno-omit-frame-pointer'
ninja -C ../ish-prof

# with the Unicorn engine (ISH_ENGINE=unicorn at runtime)
meson setup ../ish-ucp --buildtype=release -Db_ndebug=true -Dc_args='-g -fno-omit-frame-pointer' \
    -Dunicorn=enabled -Dunicorn_dir=$HOME/Projects/unicorn   # omit unicorn_dir to use Homebrew's
ninja -C ../ish-ucp
```

For the patched Unicorn, use Unicorn 2.1.4 with `unicorn.patch` applied:

```sh
git clone --depth 1 --branch 2.1.4 https://github.com/unicorn-engine/unicorn.git
cd unicorn && git apply /path/to/tools/perf/unicorn.patch
cmake -B build -DUNICORN_ARCH=x86 -DCMAKE_BUILD_TYPE=Release -DUNICORN_BUILD_TESTS=OFF   # needs pkg-config
cmake --build build -j8
```

The patch adds `uc_request_stop()`, which is safe to call from another thread, and an opt-out (`UC_NO_MEMOP_EXIT_CHECK=1`) for the helper call Unicorn puts after every guest memory access.

## Test root

The workloads run in an Alpine 3.21 x86 root, in a directory referred to as `$ISH_PROF_DATA`. Alpine 3.24's `apk` fails under iSH with `Bad address`, so don't use it.

```sh
cd $ISH_PROF_DATA
curl -LO https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86/alpine-minirootfs-3.21.8-x86.tar.gz
../ish-prof/tools/fakefsify alpine-minirootfs-3.21.8-x86.tar.gz root
# DNS over UDP fails in the command-line build, so pin the mirror
echo 'nameserver 1.1.1.1' > root/data/etc/resolv.conf
echo "$(dig +short dl-cdn.alpinelinux.org A | tail -1) dl-cdn.alpinelinux.org" >> root/data/etc/hosts
ISH=../ish-prof/ish
$ISH -f root /bin/sh -c 'apk update && apk add build-base git python3'
# Files have to be written through iSH; fakefs doesn't see files created on the host
$ISH -f root /bin/mkdir -p /prof
for f in setup.sh run.sh; do $ISH -f root /bin/sh -c "cat > /prof/$f" < /path/to/tools/perf/guest/$f; done
$ISH -f root /bin/chmod +x /prof/setup.sh /prof/run.sh
$ISH -f root /prof/setup.sh   # package cache for the apk workload, a git repo, hello.c
```

`/prof/run.sh <workload>` runs one workload inside the root:

| Workload | What it runs |
|---|---|
| `apk` | installs and removes vim from the local package cache |
| `git` | runs `git status` three times on a 1,324-file repository |
| `gcc` | runs `gcc -O2 hello.c` three times |
| `python` | runs `python3 -c pass` five times |
| `fork` | runs 300 `/bin/true` and 100 `echo \| grep` |
| `cpu` | runs a 3M-iteration Python loop |

`run.sh` exports `PATH`, because the command-line build starts processes without one, and gcc then can't find `cc1`.

## Running

```sh
export ISH_PROF_DATA=~/Projects/ish-prof-data
ISH=../ish-prof/ish tools/perf/profile.sh [workload...]   # Time Profiler, bucketed by analyze.py
ISH=../ish-ucp/ish tools/perf/compare.sh [workload...]    # asbestos vs Unicorn
```

In `analyze.py`'s buckets, "executing gadgets" includes the TLB lookups that are inlined into the gadgets. The profiler only samples threads while they run, so time spent blocked isn't counted.

Environment variables for the Unicorn engine:
- `ISH_UC_DEBUG=1` traces page faults.
- `ISH_UC_NOTICK=1` disables the ticker thread that makes threads leave the engine periodically.
