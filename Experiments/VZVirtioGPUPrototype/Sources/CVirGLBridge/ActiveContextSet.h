#ifndef RIFTVM_ACTIVE_CONTEXT_SET_H
#define RIFTVM_ACTIVE_CONTEXT_SET_H

#include <stdbool.h>
#include <stdint.h>

// Two-level bitset: preserve context order while skipping empty groups.
// Covers all uint16_t context IDs using 8 KiB plus a 128-byte index.
struct vzvg_active_context_set {
    uint64_t contexts[1024];
    uint64_t groups[16];
};

static inline void vzvg_active_context_insert(struct vzvg_active_context_set *set, uint32_t id) {
    uint32_t group = id / 64;
    set->contexts[group] |= UINT64_C(1) << (id % 64);
    set->groups[group / 64] |= UINT64_C(1) << (group % 64);
}

static inline void vzvg_active_context_remove(struct vzvg_active_context_set *set, uint32_t id) {
    uint32_t group = id / 64;
    set->contexts[group] &= ~(UINT64_C(1) << (id % 64));
    if (!set->contexts[group])
        set->groups[group / 64] &= ~(UINT64_C(1) << (group % 64));
}

static inline bool vzvg_active_context_pop(struct vzvg_active_context_set *set, uint32_t *id) {
    for (uint32_t index = 0; index < 16; index++) {
        if (!set->groups[index]) continue;
        uint32_t group = index * 64 + (uint32_t)__builtin_ctzll(set->groups[index]);
        *id = group * 64 + (uint32_t)__builtin_ctzll(set->contexts[group]);
        vzvg_active_context_remove(set, *id);
        return true;
    }
    return false;
}
#endif
