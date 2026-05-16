// mochi_bridge.c — Mochi WASM bridge for mruby
// Loads .mrb bytecode, instantiates Ruby components, renders to shared memory,
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

// ── Globals ──────────────────────────────────────────────────────
static mrb_state *g_mrb = NULL;

#define MAX_COMPONENTS 64
#define RENDER_BUF_SIZE 65536
#define EVENT_BUF_SIZE  4096

static struct {
  char id[64];
  char class_name[64];
  mrb_value instance;
  int active;
} g_components[MAX_COMPONENTS];

static uint8_t g_render_buffer[RENDER_BUF_SIZE];
static uint8_t g_event_buffer[EVENT_BUF_SIZE];
static size_t  g_render_len = 0;
static size_t  g_event_len  = 0;

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

// ── ABI Exports ──────────────────────────────────────────────────

MOCHI_EXPORT
int mochi_init_runtime(void) {
  ensure_mrb();
  return g_mrb ? 0 : -1;
}

MOCHI_EXPORT
int mochi_render_buffer_offset(void) {
  return (int)(intptr_t)g_render_buffer;
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

  mrb_value result = mrb_load_irep_buf(g_mrb, (const void *)(intptr_t)ptr, (size_t)len);

  if (g_mrb->exc) {
    mrb_value exc = mrb_obj_value(g_mrb->exc);
    mrb_value msg = mrb_funcall(g_mrb, exc, "message", 0);
    if (mrb_string_p(msg)) {
      const char *s = mrb_str_to_cstr(g_mrb, msg);
      size_t slen = strlen(s);
      if (slen > RENDER_BUF_SIZE - 1) slen = RENDER_BUF_SIZE - 1;
      memcpy(g_render_buffer, s, slen);
      g_render_buffer[slen] = '\0';
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

  int slot = find_slot(id);
  if (slot < 0) {
    slot = alloc_slot();
    if (slot < 0) return -2;
  }

  strncpy(g_components[slot].id, id, 63);
  g_components[slot].id[63] = '\0';
  strncpy(g_components[slot].class_name, class_name, 63);
  g_components[slot].class_name[63] = '\0';

  mrb_sym cls_sym = mrb_intern_cstr(g_mrb, class_name);
  mrb_value cls_val = mrb_const_get(g_mrb, mrb_obj_value(g_mrb->object_class), cls_sym);

  if (!mrb_class_p(cls_val)) return -3;

  struct RClass *cls = mrb_class_ptr(cls_val);
  mrb_value inst = mrb_obj_new(g_mrb, cls, 0, NULL);

  if (g_mrb->exc) {
    g_mrb->exc = NULL;
    return -4;
  }

  g_components[slot].instance = inst;
  mrb_gc_register(g_mrb, inst);

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

// Emscripten needs main()
int main(void) { return 0; }
