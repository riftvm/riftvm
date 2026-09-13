#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "../../Experiments/VZVirtioGPUPrototype/Sources/CVirGLBridge/ActiveContextSet.h"

static struct vzvg_active_context_set active;
static void *syncs[65536];
static volatile uint64_t checksum;

__attribute__((noinline)) static uint64_t drain_old(void) {
    uint64_t sum = 0;
    for (uint32_t id = 0; id < 65536; id++) {
        if (!syncs[id]) continue;
        sum += id + 1;
        syncs[id] = NULL;
    }
    return sum;
}

__attribute__((noinline)) static uint64_t drain_active(void) {
    uint64_t sum = 0;
    uint32_t id;
    while (vzvg_active_context_pop(&active, &id)) {
        sum += id + 1;
        syncs[id] = NULL;
    }
    return sum;
}

static double benchmark(bool optimized, unsigned count) {
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (unsigned iteration = 0; iteration < 20000; iteration++) {
        for (unsigned index = 0; index < count; index++) {
            uint32_t id = count == 1 ? 65535 : index * (65535 / (count - 1));
            syncs[id] = &active;
            if (optimized) vzvg_active_context_insert(&active, id);
        }
        checksum += optimized ? drain_active() : drain_old();
    }
    clock_gettime(CLOCK_MONOTONIC, &end);
    return ((end.tv_sec - start.tv_sec) * 1e9 + end.tv_nsec - start.tv_nsec) / 20000;
}

int main(void) {
    uint32_t id = 0;
    assert(!vzvg_active_context_pop(&active, &id));
    // Replacement is idempotent; deletion and reuse must not leave a stale bit.
    const uint32_t boundaries[] = {0, 63, 64, 4095, 4096, 65535};
    for (unsigned i = 0; i < 6; i++) {
        vzvg_active_context_insert(&active, boundaries[i]);
        vzvg_active_context_insert(&active, boundaries[i]);
        vzvg_active_context_remove(&active, boundaries[i]);
        vzvg_active_context_insert(&active, boundaries[i]);
    }
    for (unsigned i = 0; i < 6; i++) {
        assert(vzvg_active_context_pop(&active, &id));
        assert(id == boundaries[i]);
    }
    assert(!vzvg_active_context_pop(&active, &id));
    for (uint32_t i = 0; i < 65536; i++) vzvg_active_context_insert(&active, i);
    for (uint32_t i = 0; i < 65536; i += 2) vzvg_active_context_remove(&active, i);
    for (uint32_t i = 1; i < 65536; i += 2) {
        assert(vzvg_active_context_pop(&active, &id));
        assert(id == i);
    }
    assert(!vzvg_active_context_pop(&active, &id));
    puts("Active context set: boundary, replacement, removal, reuse, and full-capacity tests passed");
    puts("active contexts,old ns/iteration,new ns/iteration,speed ratio");
    unsigned counts[] = {0, 1, 4, 64};
    for (unsigned i = 0; i < 4; i++) {
        double old = benchmark(false, counts[i]);
        double new = benchmark(true, counts[i]);
        printf("%u,%.2f,%.2f,%.2f\n", counts[i], old, new, old / new);
    }
    return 0;
}
