/*
 * mochi_bridge_mruby.c — Mochi browser runtime bridge for mruby
 *
 * Linked with libmruby_core.a (NOT libmruby.a).  libmruby_core.a does
 * not reference any mruby-io or mruby-socket HAL symbols, so no HAL
 * stubs are required here.
 *
 * Provides the 10 mochi_* ABI exports for browser WASM integration.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <math.h>

#include "mruby.h"
#include "mruby/string.h"
#include "mruby/irep.h"

/* ------------------------------------------------------------------ */
/*  EMSCRIPTEN_KEEPALIVE — safe for Emscripten and native builds      */
/* ------------------------------------------------------------------ */

#ifndef EMSCRIPTEN_KEEPALIVE
  #ifdef __EMSCRIPTEN__
    #define EMSCRIPTEN_KEEPALIVE __attribute__((used))
  #else
    #define EMSCRIPTEN_KEEPALIVE
  #endif
#endif

/* ------------------------------------------------------------------ */
/*  Runtime state                                                     */
/* ------------------------------------------------------------------ */

static mrb_state *g_mrb = NULL;

static uint8_t  event_buffer[4096];
static uint32_t event_count = 0;

static uint8_t  render_buffer[65536];
static uint32_t render_len  = 0;

static uint8_t  iseq_buffer[262144];
static uint32_t iseq_len    = 0;

/* ------------------------------------------------------------------ */
/*  ABI exports — 10 mochi functions                                  */
/* ------------------------------------------------------------------ */

EMSCRIPTEN_KEEPALIVE
int mochi_init_runtime(void) {
  if (g_mrb) return 0;
  g_mrb = mrb_open();
  return g_mrb ? 0 : -1;
}

EMSCRIPTEN_KEEPALIVE
int mochi_hydrate_component(int id_ptr, int class_ptr, int raw_ptr) {
  (void)id_ptr; (void)class_ptr; (void)raw_ptr;
  if (!g_mrb) mochi_init_runtime();
  return 0;
}

EMSCRIPTEN_KEEPALIVE
int mochi_process_events(void) {
  if (!g_mrb) return -1;
  return (int)event_count;
}

EMSCRIPTEN_KEEPALIVE
int mochi_render_buffer_offset(void) {
  return (int)(intptr_t)render_buffer;
}

EMSCRIPTEN_KEEPALIVE
int mochi_event_buffer_offset(void) {
  return (int)(intptr_t)event_buffer;
}

EMSCRIPTEN_KEEPALIVE
int mochi_load_iseq(int ptr, int len) {
  if (len < 0 || (uint32_t)len > sizeof(iseq_buffer)) return -1;
  memcpy(iseq_buffer, (const void *)(intptr_t)ptr, (size_t)len);
  iseq_len = (uint32_t)len;
  return 0;
}

EMSCRIPTEN_KEEPALIVE
int mochi_malloc(int size) {
  if (!g_mrb) mochi_init_runtime();
  void *p = mrb_malloc(g_mrb, (size_t)size);
  return (int)(intptr_t)p;
}

EMSCRIPTEN_KEEPALIVE
int mochi_render(int id_ptr) {
  (void)id_ptr;
  if (!g_mrb) return -1;
  render_len = 0;
  return 0;
}

EMSCRIPTEN_KEEPALIVE
int mochi_write_event(int id_ptr, int type_ptr, int payload_ptr, int payload_len) {
  (void)id_ptr; (void)type_ptr; (void)payload_ptr; (void)payload_len;
  if (event_count < 1024) event_count++;
  return 0;
}

EMSCRIPTEN_KEEPALIVE
int mochi_reset_events(void) {
  event_count = 0;
  return 0;
}
