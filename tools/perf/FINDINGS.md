# iSH performance findings: profiling and a JIT experiment

*2026-09-23. Fork: nicscl/ish. All numbers come from the macOS command-line build of iSH on an Apple Silicon Mac, not from the iPad.*

## Question

Would an x86→ARM64 JIT make iSH meaningfully faster, and is it worth building?

**Short answer.** A JIT makes long-running computation about 2.5–3× faster. It roughly breaks even on typical short commands, and it loses on scripts that start many processes. It only pays off as a *tiered* JIT whose translations survive across processes. Cheaper wins come first: keep translations across `fork`/`exec`, and reduce fakefs overhead.

## 1. Where the time goes (asbestos, the stock engine)

Measured with the Time Profiler in Instruments (`xctrace`), and samples grouped with `bin/analyze.py`. The "running gadgets" column includes the TLB lookups that are inlined into the gadgets.

| Workload | Running gadgets | Translating | fakefs (sqlite) | fork/exec/exit |
|---|---|---|---|---|
| CPU-bound Python loop | **99%** | 0% | 0% | 0% |
| `apk add` (6 cached packages) | **95%** | 0% | 0% | 0% |
| `python3 -c pass` ×5 | **90%** | 4% | 2% | 1% |
| `gcc -O2 hello.c` ×3 | **83%** | 6% | 4% | 2% |
| 400 short processes | 49% | **19%** | 8% | **16%** |
| `git status` ×3 (1,324 files) | 37% | 3% | **53%** | 1% |

- Most workloads spend most of their time executing guest instructions, so a faster execution engine would help them.
- Scripts that start many processes pay heavily for translation and `execve`. Each new process starts with an empty translation cache (`mm_copy` → `mem_init` → `asbestos_new`).
- `git status` is dominated by fakefs metadata lookups, mostly `statx` going through a single global sqlite mutex in `fs/fake-db.c`. This is probably worse on the iPad.

## 2. Is JIT possible on the devices? (research summary)

- **M1 iPad (A14 generation, no TXM):** the classic method still works on iOS 26. Attach a debugger (Xcode or StikDebug), detach it, and JIT stays enabled.
- **A16 iPhone (TXM):** the app must cooperate. It reserves an executable region, then triggers a `brk #0xf00d` breakpoint so an attached debugger script prepares each page. This has to be redone on every cold start, and a launch without the script crashes the app. StikDebug reports that iOS 26.6 and 27 work "with a few apps" only.
- Either way, this only works in dev-signed builds, because `get-task-allow` isn't allowed on the App Store or TestFlight.
- Upstream iSH had private JIT prototypes in 2024 that gained 2–5×. Apple rejected their EU JIT request, and the maintainers say the emulator isn't designed for a JIT backend.
- Claims checked from the ChatGPT answer:
  - ish-AOK's "6.8 ns per dispatch" is real, but it was measured on an A9 iPad.
  - ish-arm64's own table shows 0.5–4.3×, not 2–12×. It is a gadget interpreter, not a JIT.
  - Running Claude Code on ish-arm64 is plausible (Bun runs with `BUN_JSC_useJIT=0`) but not demonstrated.
- Possible starting points for a real translator:
  - box64 dynarec (MIT): closest to what iSH needs, but it assumes a flat guest address space.
  - FEX-Emu (MIT): useful as a design reference.
  - Unicorn/QEMU (GPLv2): usable for measurement only.

## 3. Experiment: Unicorn as an alternative engine

To measure what native code generation would gain, without writing a JIT, I ported the stale Unicorn engine onto the iSH kernel. Unicorn is QEMU's TCG JIT packaged as a library. The existing code only worked with the separate Linux-kernel build.

**How it works (`emu/unicorn.c`):**
- It's a runtime switch in `cpu_run_to_interrupt`: set `ISH_ENGINE=unicorn`. Build with `-Dunicorn=enabled`, and optionally `-Dunicorn_dir=<patched source tree>`.
- Unicorn runs in virtual-TLB mode. Each fakefs `struct data` block gets its own lazily mapped range of Unicorn's "physical" memory. Blocks the kernel frees are unmapped before the next run, and the TLB is flushed whenever `mmu.changes` moves.
- TLS goes through a small GDT whose entries point at `tls_ptr`. `int 0x80` is caught with an interrupt hook, and page faults are passed to the kernel as `INT_GPF`.
- A ticker thread asks running engines to stop every 2 ms, so other threads can take the memory write lock.

**Bugs hit, and the fixes:**
1. Calling `uc_emu_stop` from another thread corrupted guest state. The cause is probably its per-thread JIT write-protect toggle. Fix: patched Unicorn with `uc_request_stop()`, which only kicks the vCPU. The fallback is a per-block hook that checks a flag.
2. With stock settings, 63% of the time went to Unicorn's slow path for stores, because every store was treated as a possible write to code. Unicorn only allows fast stores when the TLB entry isn't executable *and* no memory hooks are installed. Fixes:
   - Grant permissions per access type: fetches get read+exec, data accesses get read+write.
   - Remove the `UC_HOOK_MEM_INVALID` hook.
3. Unicorn inserts a helper call after every guest memory access, which exists for memory hooks. We don't use memory hooks, so a patched build skips it (`UC_NO_MEMOP_EXIT_CHECK=1`).
4. During `uc_mem_unmap`, TLB lookups hit a stale memory map. Fix: answer with identity mappings while unmapping.

**Results.** Idle machine, two passes that agree within about 5%. CPU seconds:

| Workload | asbestos | Unicorn (patched) | Unicorn vs asbestos |
|---|---|---|---|
| Python compute loop | 8.9 | 3.4 | **2.6× faster** |
| `python3 -c pass` ×5 | 0.95 | 0.80 | 1.2× faster |
| `gcc -O2 hello.c` ×3 | 1.17 | 1.46 | 1.25× slower |
| `git status` ×3 | 0.22 | 0.24 | ≈ even |
| 400 short processes | 0.43 | 1.9 | 4.4× slower |
| `apk add` | 7.0 | 386 | 55× slower (bug, see below) |

Every workload produces the same output on both engines.

**How to read these numbers:**
- **Hot loops** gain about 2.5–3× from native code. A purpose-built JIT without Unicorn's per-block overhead might reach 4–6×. That range is a guess.
- **Short-lived code** loses. TCG translation is far more expensive per block than stringing gadgets together, and each process starts with an empty cache.
- **`apk`** exposes a problem in the port, not a real cost of a JIT. The likely cause, still unconfirmed, is frequent `munmap` of large buffers: each one makes Unicorn rebuild its memory map and discard compiled code.

Translations are never kept, in either engine. They are lost when a process exits, including between two runs of the same command.

## 4. Other bugs found along the way

- Alpine 3.24's `apk` (apk-tools v3) fails under iSH with `Bad address` (EFAULT). The harness uses Alpine 3.21.
- DNS over UDP fails in the macOS command-line build with "Connection refused", so the mirror is pinned in `/etc/hosts`.
- The command-line build starts processes with no `PATH`, so gcc can't find `cc1`.
- Files created on the host inside a fakefs root are invisible to iSH. They have to be written through iSH itself.

## 5. Recommendations, in order

1. **Keep translation caches across `fork`/`exec` and across processes**, keyed by file and offset. This helps asbestos today, needs no JIT permission, and is the prerequisite for any JIT to pay off.
2. **Reduce fakefs overhead:** replace the global sqlite mutex and batch `statx` lookups. This helps `git`, `apk` and file-heavy tools.
3. **Confirm on the device.** Run one Instruments profile on the M1 iPad to check that the Mac shares hold there.
4. **Only then consider a tiered JIT:** gadgets for cold code, native code for hot blocks, M1 first. Persisting translations to disk, Rosetta-style, would be a later add-on.

## Reproducing

See [README.md](README.md) for the builds, the test root and the scripts.

- `profile.sh` produced section 1.
- `compare.sh` produced section 3.
- `unicorn.patch` is the patch to Unicorn 2.1.4 used for the "patched" numbers.

The engine is off unless iSH is built with `-Dunicorn=enabled` and run with `ISH_ENGINE=unicorn`. Unicorn is GPLv2, so builds with it enabled are for benchmarking only and must never ship.
