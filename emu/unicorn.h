#ifndef EMU_UNICORN_H
#define EMU_UNICORN_H

#include <stdbool.h>
#include <stddef.h>

struct cpu_state;

#ifdef ENGINE_UNICORN_ISH
extern bool unicorn_enabled;
void unicorn_init(void);
int unicorn_run_to_interrupt(struct cpu_state *cpu);
void unicorn_poke(struct cpu_state *cpu);
void unicorn_cpu_free(struct cpu_state *cpu);
void unicorn_data_freed(void *host, size_t size);
#else
#define unicorn_enabled false
static inline void unicorn_init(void) {}
static inline int unicorn_run_to_interrupt(struct cpu_state *cpu) { return -1; }
static inline void unicorn_poke(struct cpu_state *cpu) {}
static inline void unicorn_cpu_free(struct cpu_state *cpu) {}
static inline void unicorn_data_freed(void *host, size_t size) {}
#endif

#endif
