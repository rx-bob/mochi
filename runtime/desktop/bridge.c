// Upstream's offset accessors narrow pointers to wasm32. Expose the same
// buffers at native pointer width without modifying the shared VM.
#include "mochi_gvm_bridge.c"

const uint8_t *desktop_patch_data(void) { return g_patch_buffer; }
const char *desktop_vm_error(void) { return g_error_text; }
