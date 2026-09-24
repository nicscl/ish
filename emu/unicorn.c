// Experimental alternative CPU engine that runs guest code with Unicorn (QEMU's
// TCG JIT) instead of asbestos. Enabled at runtime with ISH_ENGINE=unicorn when
// built with -Dunicorn=enabled. Intended for measuring what a real code
// generator would gain, not for shipping (Unicorn is GPLv2).
//
// Memory: Unicorn runs in virtual-TLB mode. Every guest page lives in some
// struct data (one host mmap), so each data block gets its own range of
// Unicorn "physical" memory, mapped lazily on the first TLB fill that touches
// it. Blocks freed by the kernel are unmapped again before the next run.
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <unicorn/unicorn.h>

#include "debug.h"
#include "emu/cpu.h"
#include "emu/interrupt.h"
#include "emu/unicorn.h"
#include "kernel/memory.h"

bool unicorn_enabled;

// Only in our patched Unicorn: kicks the vCPU without uc_emu_stop's JIT
// write-protect toggling, so it's safe from another thread.
static void (*request_stop_fn)(uc_engine *uc);

struct engine;
static void request_stop(struct engine *e);

#define check(err) do { \
    uc_err __err = (err); \
    if (__err != UC_ERR_OK) die("%s:%d: unicorn: %s", __FILE__, __LINE__, uc_strerror(__err)); \
} while (0)

// Physical layout: GDT page at GDT_PHYS, data blocks allocated upward from PHYS_BASE.
#define GDT_PHYS 0x1000ull
#define GDT_VADDR 0xfffff000u
#define PHYS_BASE 0x100000ull
#define PHYS_LIMIT (1ull << 36)
#define TICK_USEC 2000

struct block_map {
    void *host;
    uint64_t phys;
    size_t size;
};

struct engine {
    uc_engine *uc;
    struct cpu_state *owner; // cpu_state gets copied on fork, so check this
    struct mem *mem;
    uint64_t mem_changes;
    addr_t tls_ptr;
    word_t gs;
    uint64_t next_phys;
    uint64_t freed_seen;

    struct block_map *blocks;
    size_t blocks_cap, blocks_used;

    uint32_t *gdt; // host page backing the GDT

    // fault info from hooks
    addr_t fault_addr;
    bool fault_write;
    bool faulted;
    // uc_mem_unmap looks its range up through the TLB to invalidate code, so
    // answer with identity mappings while unmapping our physical ranges
    bool unmapping;

    bool stop_requested; // set by the ticker or a poke, checked on each block
    struct list running_link;
};

// ---- freed data blocks, shared by all engines ----
#define FREED_RING 65536
static struct { void *host; size_t size; } freed_ring[FREED_RING];
static uint64_t freed_count;
static pthread_mutex_t freed_lock = PTHREAD_MUTEX_INITIALIZER;

void unicorn_data_freed(void *host, size_t size) {
    if (!unicorn_enabled)
        return;
    pthread_mutex_lock(&freed_lock);
    freed_ring[freed_count % FREED_RING].host = host;
    freed_ring[freed_count % FREED_RING].size = size;
    freed_count++;
    pthread_mutex_unlock(&freed_lock);
}

// ---- block map: open addressing keyed by host pointer ----
static size_t block_slot(struct engine *e, void *host) {
    size_t h = ((uintptr_t) host >> 12) * 0x9e3779b97f4a7c15ull;
    size_t mask = e->blocks_cap - 1;
    for (size_t i = h & mask;; i = (i + 1) & mask) {
        if (e->blocks[i].host == host || e->blocks[i].host == NULL)
            return i;
    }
}

static void blocks_grow(struct engine *e) {
    struct block_map *old = e->blocks;
    size_t old_cap = e->blocks_cap;
    e->blocks_cap = old_cap ? old_cap * 2 : 1024;
    e->blocks = calloc(e->blocks_cap, sizeof(*e->blocks));
    for (size_t i = 0; i < old_cap; i++)
        if (old[i].host != NULL)
            e->blocks[block_slot(e, old[i].host)] = old[i];
    free(old);
}

static void blocks_remove_slot(struct engine *e, size_t i) {
    // backward-shift deletion keeps probe chains intact
    size_t mask = e->blocks_cap - 1;
    e->blocks[i].host = NULL;
    e->blocks_used--;
    for (size_t j = (i + 1) & mask; e->blocks[j].host != NULL; j = (j + 1) & mask) {
        struct block_map b = e->blocks[j];
        e->blocks[j].host = NULL;
        e->blocks[block_slot(e, b.host)] = b;
    }
}

static void unmap_all(struct engine *e) {
    e->unmapping = true;
    for (size_t i = 0; i < e->blocks_cap; i++) {
        if (e->blocks[i].host != NULL) {
            check(uc_mem_unmap(e->uc, e->blocks[i].phys, e->blocks[i].size));
            e->blocks[i].host = NULL;
        }
    }
    e->blocks_used = 0;
    e->next_phys = PHYS_BASE;
    e->unmapping = false;
    check(uc_ctl_flush_tlb(e->uc));
}

static uint64_t block_phys(struct engine *e, struct data *data) {
    if (e->blocks_used * 2 >= e->blocks_cap)
        blocks_grow(e);
    size_t i = block_slot(e, data->data);
    if (e->blocks[i].host != NULL)
        return e->blocks[i].phys;
    if (e->next_phys + data->size > PHYS_LIMIT) {
        unmap_all(e);
        i = block_slot(e, data->data);
    }
    uint64_t phys = e->next_phys;
    e->next_phys += (data->size + 0xfff) & ~0xfffull;
    check(uc_mem_map_ptr(e->uc, phys, (data->size + 0xfff) & ~0xfffull, UC_PROT_ALL, data->data));
    e->blocks[i] = (struct block_map) {data->data, phys, (data->size + 0xfff) & ~0xfffull};
    e->blocks_used++;
    return phys;
}

static void process_freed(struct engine *e) {
    pthread_mutex_lock(&freed_lock);
    uint64_t count = freed_count;
    if (count - e->freed_seen > FREED_RING) {
        pthread_mutex_unlock(&freed_lock);
        unmap_all(e);
        e->freed_seen = count;
        return;
    }
    bool unmapped = false;
    e->unmapping = true;
    for (uint64_t n = e->freed_seen; n < count; n++) {
        void *host = freed_ring[n % FREED_RING].host;
        if (e->blocks_cap == 0)
            break;
        size_t i = block_slot(e, host);
        if (e->blocks[i].host == host) {
            check(uc_mem_unmap(e->uc, e->blocks[i].phys, e->blocks[i].size));
            blocks_remove_slot(e, i);
            unmapped = true;
        }
    }
    e->unmapping = false;
    if (unmapped)
        check(uc_ctl_flush_tlb(e->uc));
    e->freed_seen = count;
    pthread_mutex_unlock(&freed_lock);
}

// ---- hooks ----
static bool hook_tlb_fill(uc_engine *uc, uint64_t vaddr, uc_mem_type type, uc_tlb_entry *result, void *user_data) {
    struct engine *e = user_data;
    if (e->unmapping) {
        result->paddr = vaddr & ~0xfffull;
        result->perms = UC_PROT_ALL;
        return true;
    }
    page_t page = PAGE((addr_t) vaddr);
    struct pt_entry *entry = e->mem ? mem_pt(e->mem, page) : NULL;
    if (entry == NULL) {
        if (page == PAGE(GDT_VADDR)) {
            result->paddr = GDT_PHYS;
            result->perms = UC_PROT_READ | UC_PROT_WRITE;
            return true;
        }
        e->fault_addr = vaddr;
        e->fault_write = type == UC_MEM_WRITE;
        e->faulted = true;
        return false;
    }
    result->paddr = block_phys(e, entry->data) + entry->offset;
    // Unicorn only lets stores skip its slow self-modifying-code path when the
    // TLB entry isn't executable, so writable pages get exec only while being
    // fetched from. Each switch between the two just refills the entry.
    if (!P_WRITABLE(entry->flags))
        result->perms = UC_PROT_READ | UC_PROT_EXEC;
    else if (type == UC_MEM_FETCH)
        result->perms = UC_PROT_READ | UC_PROT_EXEC;
    else
        result->perms = UC_PROT_READ | UC_PROT_WRITE;
    if (type == UC_MEM_WRITE && !P_WRITABLE(entry->flags)) {
        e->fault_addr = vaddr;
        e->fault_write = true;
        e->faulted = true;
    }
    return true;
}

static void hook_block(uc_engine *uc, uint64_t address, uint32_t size, void *user_data) {
    struct engine *e = user_data;
    if (__atomic_load_n(&e->stop_requested, __ATOMIC_RELAXED))
        uc_emu_stop(uc);
}

static void hook_intr(uc_engine *uc, uint32_t intno, void *user_data) {
    struct engine *e = user_data;
    e->owner->trapno = intno;
    uc_emu_stop(uc);
}

// ---- running list and ticker, so threads leave the engine regularly ----
static pthread_mutex_t running_lock = PTHREAD_MUTEX_INITIALIZER;
static struct list running = {&running, &running};

static void *ticker(void *unused) {
    for (;;) {
        usleep(TICK_USEC);
        pthread_mutex_lock(&running_lock);
        struct engine *e;
        list_for_each_entry(&running, e, running_link)
            request_stop(e);
        pthread_mutex_unlock(&running_lock);
    }
    return NULL;
}

void unicorn_init(void) {
    const char *engine = getenv("ISH_ENGINE");
    unicorn_enabled = engine != NULL && strcmp(engine, "unicorn") == 0;
    if (!unicorn_enabled)
        return;
    request_stop_fn = (void (*)(uc_engine *)) dlsym(RTLD_DEFAULT, "uc_request_stop");
    if (getenv("ISH_UC_NOTICK"))
        return;
    pthread_t thread;
    pthread_create(&thread, NULL, ticker, NULL);
    pthread_detach(thread);
}

// ---- GDT, for gs-based TLS ----
static void set_gdt_entry(struct engine *e, int index, uint32_t base, int dpl) {
    uint32_t limit = 0xfffff;
    e->gdt[index * 2] = (limit & 0xffff) | (base << 16);
    e->gdt[index * 2 + 1] = ((base >> 16) & 0xff) | ((0x93 | dpl << 5) << 8) /* present, rw data */
        | (limit & 0xf0000) | (0xc << 20) /* 4k granularity, 32 bit */ | (base & 0xff000000);
}

static struct engine *engine_new(struct cpu_state *cpu) {
    struct engine *e = calloc(1, sizeof(*e));
    e->owner = cpu;
    e->next_phys = PHYS_BASE;
    check(uc_open(UC_ARCH_X86, UC_MODE_32, &e->uc));
    check(uc_ctl_tlb_mode(e->uc, UC_TLB_VIRTUAL));
    uc_hook hh;
    check(uc_hook_add(e->uc, &hh, UC_HOOK_TLB_FILL, hook_tlb_fill, e, 1, 0));
    // no UC_HOOK_MEM_* hooks: any of them sends every store down Unicorn's slow path
    check(uc_hook_add(e->uc, &hh, UC_HOOK_INTR, hook_intr, e, 1, 0));
    // uc_emu_stop from another thread can leave the guest state inconsistent,
    // so other threads only raise a flag and the engine stops itself
    if (request_stop_fn == NULL && !getenv("ISH_UC_NOTICK"))
        check(uc_hook_add(e->uc, &hh, UC_HOOK_BLOCK, hook_block, e, 1, 0));

    e->gdt = aligned_alloc(0x1000, 0x1000);
    memset(e->gdt, 0, 0x1000);
    check(uc_mem_map_ptr(e->uc, GDT_PHYS, 0x1000, UC_PROT_READ | UC_PROT_WRITE, e->gdt));
    uc_x86_mmr gdtr = {.base = GDT_VADDR, .limit = 0xfff};
    check(uc_reg_write(e->uc, UC_X86_REG_GDTR, &gdtr));
    // Loading any segment register without a proper ss makes esp 16 bit, so
    // give ss a flat 32 bit segment first.
    set_gdt_entry(e, 1, 0, 0);
    int ss = 1 << 3;
    check(uc_reg_write(e->uc, UC_X86_REG_SS, &ss));
    e->freed_seen = freed_count;
    return e;
}

void unicorn_cpu_free(struct cpu_state *cpu) {
    struct engine *e = cpu->unicorn;
    if (e == NULL || e->owner != cpu)
        return;
    uc_close(e->uc);
    free(e->gdt);
    free(e->blocks);
    free(e);
    cpu->unicorn = NULL;
}

static const int gpr_ids[8] = {
    UC_X86_REG_EAX, UC_X86_REG_ECX, UC_X86_REG_EDX, UC_X86_REG_EBX,
    UC_X86_REG_ESP, UC_X86_REG_EBP, UC_X86_REG_ESI, UC_X86_REG_EDI,
};

int unicorn_run_to_interrupt(struct cpu_state *cpu) {
    struct engine *e = cpu->unicorn;
    if (e == NULL || e->owner != cpu)
        e = cpu->unicorn = engine_new(cpu);
    uc_engine *uc = e->uc;

    struct mem *mem = container_of(cpu->mmu, struct mem, mmu);
    process_freed(e);
    if (e->mem != mem || e->mem_changes != mem->mmu.changes) {
        e->mem = mem;
        e->mem_changes = mem->mmu.changes;
        check(uc_ctl_flush_tlb(uc));
    }

    void *vals[10];
    int ids[10];
    for (int i = 0; i < 8; i++) {
        ids[i] = gpr_ids[i];
        vals[i] = &cpu->regs[i];
    }
    collapse_flags(cpu);
    ids[8] = UC_X86_REG_EIP; vals[8] = &cpu->eip;
    ids[9] = UC_X86_REG_EFLAGS; vals[9] = &cpu->eflags;
    check(uc_reg_write_batch(uc, ids, vals, 10));
    if (cpu->tls_ptr != e->tls_ptr || cpu->gs != e->gs) {
        e->tls_ptr = cpu->tls_ptr;
        e->gs = cpu->gs;
        // Linux's TLS entries; musl loads gs from whichever set_thread_area returned
        for (int i = 6; i <= 14; i++)
            set_gdt_entry(e, i, cpu->tls_ptr, 3);
        int gs = cpu->gs;
        check(uc_reg_write(uc, UC_X86_REG_GS, &gs));
    }

    cpu->trapno = INT_NONE;
    __atomic_store_n(&e->stop_requested, false, __ATOMIC_RELAXED);
    e->faulted = false;
    int interrupt = INT_TIMER;
    if (!__atomic_exchange_n(cpu->poked_ptr, false, __ATOMIC_SEQ_CST)) {
        pthread_mutex_lock(&running_lock);
        list_add(&running, &e->running_link);
        pthread_mutex_unlock(&running_lock);

        uc_err err = uc_emu_start(uc, cpu->eip, 0, 0, 0);

        pthread_mutex_lock(&running_lock);
        list_remove(&e->running_link);
        pthread_mutex_unlock(&running_lock);

        switch (err) {
            case UC_ERR_OK:
                if (cpu->trapno != INT_NONE)
                    interrupt = cpu->trapno;
                break;
            case UC_ERR_EXCEPTION:
                if (!e->faulted)
                    goto unhandled;
                // fallthrough
            case UC_ERR_READ_UNMAPPED: case UC_ERR_WRITE_UNMAPPED: case UC_ERR_FETCH_UNMAPPED:
            case UC_ERR_READ_PROT: case UC_ERR_WRITE_PROT: case UC_ERR_FETCH_PROT:
                interrupt = INT_GPF;
                cpu->segfault_addr = e->fault_addr;
                cpu->segfault_was_write = e->fault_write;
                if (getenv("ISH_UC_DEBUG")) {
                    dword_t eip;
                    uc_reg_read(uc, UC_X86_REG_EIP, &eip);
                    fprintf(stderr, "uc fault err=%d addr=%#x write=%d eip=%#x\n", err, e->fault_addr, e->fault_write, eip);
                }
                break;
            case UC_ERR_INSN_INVALID:
                interrupt = INT_UNDEFINED;
                break;
            default: unhandled: {
                dword_t eip;
                uc_reg_read(uc, UC_X86_REG_EIP, &eip);
                fprintf(stderr, "unicorn: %s (%d) at %#x, fault %#x\n", uc_strerror(err), err, eip, e->fault_addr);
                die("unicorn: %s at %#x", uc_strerror(err), eip);
            }
        }
    }

    check(uc_reg_read_batch(uc, ids, vals, 10));
    int gs;
    check(uc_reg_read(uc, UC_X86_REG_GS, &gs));
    cpu->gs = e->gs = gs;
    expand_flags(cpu);
    return interrupt;
}

// called with running_lock held
static void request_stop(struct engine *e) {
    if (request_stop_fn != NULL)
        request_stop_fn(e->uc);
    else
        __atomic_store_n(&e->stop_requested, true, __ATOMIC_RELAXED);
}

void unicorn_poke(struct cpu_state *cpu) {
    pthread_mutex_lock(&running_lock);
    struct engine *e = cpu->unicorn;
    if (e != NULL && e->owner == cpu) {
        struct engine *r;
        list_for_each_entry(&running, r, running_link)
            if (r == e)
                request_stop(e);
    }
    pthread_mutex_unlock(&running_lock);
}
