// mochi_bridge.c — Mochi WASM bridge for mruby
// Loads .chi bytecode, instantiates Ruby components, renders to shared memory,
// processes events via shared memory buffers.

#include <mruby.h>
#include <mruby/class.h>
#include <mruby/string.h>
#include <mruby/variable.h>
#include <mruby/irep.h>
#include <mruby/error.h>
#include <mruby/compile.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#define MOCHI_EXPORT EMSCRIPTEN_KEEPALIVE
#else
#define MOCHI_EXPORT __attribute__((used))
#endif

#ifdef MOCHI_ABI_OWNS_GOOSE_LIFECYCLE
extern void goose_init(int argc, char **argv);
#endif
extern const uint8_t *goose_vm_last_error(int64_t *out_len);
extern const char *mrb_abi_last_error(mrb_state *mrb);

// ── Globals ──────────────────────────────────────────────────────
static mrb_state *g_mrb = NULL;

#define MAX_COMPONENTS 64
#define RENDER_BUF_SIZE 65536
#define EVENT_BUF_SIZE  4096
#define FETCH_BUF_SIZE  65536
#define TAG_BUF_SIZE    128

static struct {
  char id[64];
  char class_name[64];
  mrb_value instance;
  int active;
} g_components[MAX_COMPONENTS];

static uint8_t g_render_buffer[RENDER_BUF_SIZE];
static uint8_t g_css_buffer[RENDER_BUF_SIZE];
static uint8_t g_tag_buffer[TAG_BUF_SIZE];
static uint8_t g_event_buffer[EVENT_BUF_SIZE];
static size_t  g_render_len = 0;
static size_t  g_event_len  = 0;

// Fetch bridge: outbox (Ruby→JS requests), inbox (JS→Ruby responses)
static uint8_t g_fetch_outbox[FETCH_BUF_SIZE];  // Ruby writes: "id|component|callback|url\n"
static size_t  g_fetch_outbox_len = 0;
static uint8_t g_fetch_inbox[FETCH_BUF_SIZE];    // JS writes response body here
static int     g_fetch_next_id = 1;

// ── Internal helpers ─────────────────────────────────────────────
static void ensure_mrb(void) {
  if (!g_mrb) g_mrb = mrb_open();
}

static int find_slot(const char *id) {
  for (int i = 0; i < MAX_COMPONENTS; i++) {
    if (g_components[i].active && strcmp(g_components[i].id, id) == 0)
      return i;
  }
  return -1;
}

static int alloc_slot(void) {
  for (int i = 0; i < MAX_COMPONENTS; i++) {
    if (!g_components[i].active) {
      g_components[i].active = 1;
      return i;
    }
  }
  return -1;
}

static void copy_abi_error(const char *fallback) {
  int64_t err_len = 0;
  const uint8_t *err = goose_vm_last_error(&err_len);
  size_t copy = 0;

  if (err && err_len > 0) {
    copy = (size_t)err_len;
    if (copy > RENDER_BUF_SIZE - 1) copy = RENDER_BUF_SIZE - 1;
    memcpy(g_render_buffer, err, copy);
  } else if (fallback) {
    copy = strlen(fallback);
    if (copy > RENDER_BUF_SIZE - 1) copy = RENDER_BUF_SIZE - 1;
    memcpy(g_render_buffer, fallback, copy);
  }
  g_render_buffer[copy] = '\0';
}

static int call_string_method(int id_ptr, const char *method,
                              uint8_t *buffer, size_t capacity,
                              size_t *out_len) {
  ensure_mrb();
  if (!g_mrb || !buffer || capacity == 0 || !method) return -1;

  const char *id = (const char *)(intptr_t)id_ptr;
  if (!id) return -1;

  int slot = find_slot(id);
  if (slot < 0) return -1;

  g_mrb->exc = NULL;
  mrb_sym method_sym = mrb_intern_cstr(g_mrb, method);
  mrb_value value = mrb_funcall_argv(
    g_mrb, g_components[slot].instance, method_sym, 0, NULL);

  if (g_mrb->exc) {
    g_mrb->exc = NULL;
    return -2;
  }
  if (!mrb_string_p(value)) return -3;

  size_t length = RSTRING_LEN(value);
  if (length > capacity - 1) length = capacity - 1;
  memcpy(buffer, RSTRING_PTR(value), length);
  buffer[length] = '\0';
  if (out_len) *out_len = length;
  return (int)length;
}

static int call_lifecycle(int slot, const char *name) {
  if (!g_mrb || slot < 0 || slot >= MAX_COMPONENTS ||
      !g_components[slot].active || !name) {
    return -1;
  }

  g_mrb->exc = NULL;
  mrb_sym method_sym = mrb_intern_cstr(g_mrb, name);
  mrb_funcall_argv(g_mrb, g_components[slot].instance, method_sym, 0, NULL);

  if (!g_mrb->exc) return 0;

  const char *message = mrb_abi_last_error(g_mrb);
  int missing = message && strcmp(message, "unknown method") == 0;
  g_mrb->exc = NULL;
  return missing ? 1 : -3;
}

// ── ABI Exports ──────────────────────────────────────────────────

static void register_mochi_module(void);

MOCHI_EXPORT
int mochi_init_runtime(void) {
#ifdef MOCHI_ABI_OWNS_GOOSE_LIFECYCLE
  goose_init(0, NULL);
#endif
  ensure_mrb();
  if (!g_mrb) return -1;
  register_mochi_module();
  if (g_mrb->exc) {
    g_mrb->exc = NULL;
    return -2;
  }
  return 0;
}

MOCHI_EXPORT
int mochi_render_buffer_offset(void) {
  return (int)(intptr_t)g_render_buffer;
}

MOCHI_EXPORT
int mochi_css_buffer_offset(void) {
  return (int)(intptr_t)g_css_buffer;
}

MOCHI_EXPORT
int mochi_tag_buffer_offset(void) {
  return (int)(intptr_t)g_tag_buffer;
}

MOCHI_EXPORT
int mochi_event_buffer_offset(void) {
  return (int)(intptr_t)g_event_buffer;
}

MOCHI_EXPORT
int mochi_malloc(int size) {
  ensure_mrb();
  if (!g_mrb) return 0;
  void *p = mrb_malloc(g_mrb, (size_t)size);
  return (int)(intptr_t)p;
}

MOCHI_EXPORT
int mochi_load_iseq(int ptr, int len) {
  ensure_mrb();
  if (!g_mrb || !ptr || len <= 0) return -1;

  g_mrb->exc = NULL;
  mrb_load_irep_buf(g_mrb, (const void *)(intptr_t)ptr, (size_t)len);

  if (g_mrb->exc) {
    const char *message = mrb_abi_last_error(g_mrb);
    if (message && message[0]) {
      size_t slen = strlen(message);
      if (slen > RENDER_BUF_SIZE - 1) slen = RENDER_BUF_SIZE - 1;
      memcpy(g_render_buffer, message, slen);
      g_render_buffer[slen] = '\0';
    } else {
      copy_abi_error("irep load failed");
    }
    g_mrb->exc = NULL;
    return -2;
  }
  return 0;
}

MOCHI_EXPORT
int mochi_hydrate_component(int id_ptr, int class_ptr, int state_ptr) {
  ensure_mrb();
  if (!g_mrb) return -1;

  const char *id = (const char *)(intptr_t)id_ptr;
  const char *class_name = (const char *)(intptr_t)class_ptr;
  if (!id || !class_name) return -1;

  g_mrb->exc = NULL;
  mrb_sym cls_sym = mrb_intern_cstr(g_mrb, class_name);
  mrb_value cls_val = mrb_const_get(g_mrb, mrb_obj_value(g_mrb->object_class), cls_sym);

  if (!mrb_class_p(cls_val)) {
    g_mrb->exc = NULL;
    return -3;
  }

  struct RClass *cls = mrb_class_ptr(cls_val);
  mrb_value inst = mrb_obj_new(g_mrb, cls, 0, NULL);

  if (g_mrb->exc) {
    g_mrb->exc = NULL;
    return -4;
  }

  int slot = find_slot(id);
  if (slot < 0) {
    slot = alloc_slot();
    if (slot < 0) return -2;
  }

  strncpy(g_components[slot].id, id, 63);
  g_components[slot].id[63] = '\0';
  strncpy(g_components[slot].class_name, class_name, 63);
  g_components[slot].class_name[63] = '\0';
  g_components[slot].instance = inst;
  mrb_gc_register(g_mrb, inst);

  int lifecycle = call_lifecycle(slot, "mounted");
  if (lifecycle < 0) {
    g_components[slot].active = 0;
    g_components[slot].instance = mrb_nil_value();
    return -5;
  }

  (void)state_ptr;
  return slot;
}

MOCHI_EXPORT
int mochi_render(int id_ptr) {
  ensure_mrb();
  if (!g_mrb) return -1;

  const char *id = (const char *)(intptr_t)id_ptr;
  if (!id) return -1;

  int slot = find_slot(id);
  if (slot < 0) return -1;

  mrb_sym html_sym = mrb_intern_cstr(g_mrb, "html");
  mrb_value html = mrb_funcall_argv(g_mrb, g_components[slot].instance, html_sym, 0, NULL);

  if (g_mrb->exc) {
    g_mrb->exc = NULL;
    return -2;
  }

  if (!mrb_string_p(html)) return -3;

  size_t slen = RSTRING_LEN(html);
  if (slen > RENDER_BUF_SIZE - 1) slen = RENDER_BUF_SIZE - 1;
  memcpy(g_render_buffer, RSTRING_PTR(html), slen);
  g_render_buffer[slen] = '\0';
  g_render_len = slen;
  return (int)slen;
}

MOCHI_EXPORT
int mochi_component_css(int id_ptr) {
  return call_string_method(
    id_ptr, "css", g_css_buffer, sizeof(g_css_buffer), NULL);
}

MOCHI_EXPORT
int mochi_component_tag(int id_ptr) {
  return call_string_method(
    id_ptr, "tag_name", g_tag_buffer, sizeof(g_tag_buffer), NULL);
}

MOCHI_EXPORT
int mochi_invoke_lifecycle(int id_ptr, int name_ptr) {
  ensure_mrb();
  if (!g_mrb) return -1;

  const char *id = (const char *)(intptr_t)id_ptr;
  const char *name = (const char *)(intptr_t)name_ptr;
  if (!id || !name) return -1;

  int slot = find_slot(id);
  if (slot < 0) return -2;

  return call_lifecycle(slot, name);
}

MOCHI_EXPORT
int mochi_write_event(int line_ptr) {
  const char *line = (const char *)(intptr_t)line_ptr;
  if (!line) return -1;
  size_t len = strlen(line);
  if (g_event_len + len + 1 >= EVENT_BUF_SIZE) return -2;
  memcpy(g_event_buffer + g_event_len, line, len);
  g_event_buffer[g_event_len + len] = '\n';
  g_event_len += len + 1;
  return (int)len;
}

MOCHI_EXPORT
int mochi_process_events(void) {
  ensure_mrb();
  if (!g_mrb || g_event_len == 0) return 0;

  int processed = 0;
  g_event_buffer[g_event_len] = '\0';

  char *line = (char *)g_event_buffer;
  char *end  = (char *)g_event_buffer + g_event_len;

  while (line < end && *line) {
    char *nl = memchr(line, '\n', end - line);
    if (!nl) nl = end;
    *nl = '\0';

    // Format: "component-id|event-type|method-name"
    char *p1 = strchr(line, '|');
    if (p1) {
      *p1 = '\0';
      char *p2 = strchr(p1 + 1, '|');
      if (p2) {
        *p2 = '\0';
        char *method = p2 + 1;

        int slot = find_slot(line);
        if (slot >= 0) {
          mrb_sym ms = mrb_intern_cstr(g_mrb, method);
          mrb_funcall_argv(g_mrb, g_components[slot].instance, ms, 0, NULL);
          if (g_mrb->exc) g_mrb->exc = NULL;
          processed++;
        }
      }
    }

    line = nl + 1;
  }

  g_event_len = 0;
  return processed;
}

MOCHI_EXPORT
int mochi_reset_events(void) {
  g_event_len = 0;
  g_event_buffer[0] = '\0';
  return 0;
}

// ── Fetch Bridge ─────────────────────────────────────────────────
// Ruby writes requests to outbox, JS reads them, fetches, writes
// response to inbox, then calls mochi_deliver_fetch.

MOCHI_EXPORT
int mochi_fetch_outbox_offset(void) {
  return (int)(intptr_t)g_fetch_outbox;
}

MOCHI_EXPORT
int mochi_fetch_outbox_len(void) {
  return (int)g_fetch_outbox_len;
}

MOCHI_EXPORT
int mochi_fetch_outbox_clear(void) {
  g_fetch_outbox_len = 0;
  g_fetch_outbox[0] = '\0';
  return 0;
}

MOCHI_EXPORT
int mochi_fetch_inbox_offset(void) {
  return (int)(intptr_t)g_fetch_inbox;
}

// JS calls this after writing response body to inbox buffer.
// Finds the component and calls its callback method with the response string.
MOCHI_EXPORT
int mochi_deliver_fetch(int comp_id_ptr, int callback_ptr, int resp_len) {
  ensure_mrb();
  if (!g_mrb) return -1;

  const char *comp_id = (const char *)(intptr_t)comp_id_ptr;
  const char *callback = (const char *)(intptr_t)callback_ptr;
  if (!comp_id || !callback) return -1;

  int slot = find_slot(comp_id);
  if (slot < 0) return -2;

  // Build a Ruby string from the inbox buffer
  mrb_value resp_str = mrb_str_new(g_mrb, (const char *)g_fetch_inbox, (size_t)resp_len);

  // Call component.callback(response_string)
  mrb_sym cb_sym = mrb_intern_cstr(g_mrb, callback);
  mrb_funcall_argv(g_mrb, g_components[slot].instance, cb_sym, 1, &resp_str);

  if (g_mrb->exc) {
    g_mrb->exc = NULL;
    return -3;
  }
  return 0;
}

// Ruby-callable: Mochi.fetch(component_id, url, callback_method)
// Writes "fetch_id|component_id|callback|url\n" to outbox for JS to pick up.
static mrb_value mrb_mochi_fetch(mrb_state *mrb, mrb_value self) {
  const char *comp_id, *url, *callback;
  (void)self;
  mrb_get_args(mrb, "zzz", &comp_id, &url, &callback);

  int fetch_id = g_fetch_next_id++;

  // Format: "fetch_id|component_id|callback|url\n"
  char line[1024];
  int n = snprintf(line, sizeof(line), "%d|%s|%s|%s\n", fetch_id, comp_id, callback, url);
  if (n <= 0 || g_fetch_outbox_len + (size_t)n >= FETCH_BUF_SIZE) {
    return mrb_fixnum_value(-1);
  }
  memcpy(g_fetch_outbox + g_fetch_outbox_len, line, (size_t)n);
  g_fetch_outbox_len += (size_t)n;

  return mrb_fixnum_value(fetch_id);
}

static void register_mochi_module(void) {
  struct RClass *mochi_mod = mrb_define_module(g_mrb, "Mochi");
  mrb_define_module_function(g_mrb, mochi_mod, "fetch",
    mrb_mochi_fetch, MRB_ARGS_REQ(3));
}

// Emscripten needs main()
int main(void) { return 0; }
