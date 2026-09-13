// Exercise the real bridge lifecycle with deterministic EGL/renderer callbacks.
#include <assert.h>
#include "../../Experiments/VZVirtioGPUPrototype/Sources/CVirGLBridge/CVirGLBridge.c"

static uintptr_t next_sync = 1;
static unsigned destroyed, waited, cleanups;
static bool fail_wait;
static int submit_ok(void *commands, int context, int count) { return 0; }
static void noop(void) {}
static void destroy_context_stub(uint32_t id) {}
static void cleanup_stub(void *cookie) { cleanups++; }
static EGLSync create_sync_stub(EGLDisplay display, int type, const intptr_t *attributes) {
    return (EGLSync)next_sync++;
}
static EGLBoolean destroy_sync_stub(EGLDisplay display, EGLSync sync) {
    assert(sync); destroyed++; return 1;
}
static EGLBoolean wait_sync_stub(EGLDisplay display, EGLSync sync, int flags) {
    assert(sync); waited++; return !fail_wait;
}
static int get_error_stub(void) { return 0; }
static int borrow_stub(int id, struct virgl_renderer_resource_info_ext *info) { return -1; }

int main(void) {
    submit_cmd = submit_ok;
    gl_flush = noop;
    egl_create_sync = create_sync_stub;
    egl_destroy_sync = destroy_sync_stub;
    egl_wait_sync = wait_sync_stub;
    egl_get_error = get_error_stub;
    force_context_zero = noop;
    context_destroy = destroy_context_stub;
    renderer_cleanup = cleanup_stub;
    borrow_texture_for_scanout = borrow_stub;
    assert(vzvg_renderer_submit(NULL, 65535, 0) == 0);
    assert(vzvg_renderer_submit(NULL, 65535, 0) == 0);
    assert(destroyed == 1); // Replacement retires exactly the older sync.
    vzvg_renderer_context_destroy(65535);
    assert(destroyed == 2);
    vzvg_renderer_submit(NULL, 65535, 0); // Reused ID is active again.
    vzvg_renderer_submit(NULL, 64, 0);
    fail_wait = true;
    assert(vzvg_renderer_present_scanout(1, (void *)1, 0, 0, 1, 1, 1, 1) == -1);
    assert(waited == 1 && destroyed == 3);
    assert(guest_context_syncs[64] == NULL);
    assert(guest_context_syncs[65535] != NULL); // Retry retains unvisited work.
    fail_wait = false;
    assert(vzvg_renderer_present_scanout(1, (void *)1, 0, 0, 1, 1, 1, 1) == -1);
    assert(waited == 2 && destroyed == 4);
    vzvg_renderer_submit(NULL, 0, 0);
    vzvg_renderer_submit(NULL, 4096, 0);
    vzvg_renderer_cleanup();
    assert(destroyed == 6 && cleanups == 1);
    uint32_t id;
    assert(!vzvg_active_context_pop(&active_guest_contexts, &id));
    puts("Bridge sync lifecycle: replacement, destroy/reuse, failed wait/retry, cleanup passed");
}
