#include <jni.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <ghostty/vt.h>

typedef struct {
  uint8_t *data;
  size_t len;
  size_t cap;
} Bytes;

typedef struct {
  GhosttyTerminal terminal;
  GhosttyRenderState render;
  GhosttyRenderStateRowIterator rows;
  GhosttyRenderStateRowCells cells;
  GhosttyKeyEncoder encoder;
  GhosttyKeyEvent key_event;
  Bytes replies;
} ZukoTerminal;

static void throw_runtime(JNIEnv *env, const char *message) {
  jclass type = (*env)->FindClass(env, "java/lang/IllegalStateException");
  if (type != NULL) (*env)->ThrowNew(env, type, message);
}

static bool bytes_reserve(Bytes *bytes, size_t additional) {
  if (additional > SIZE_MAX - bytes->len) return false;
  const size_t required = bytes->len + additional;
  if (required <= bytes->cap) return true;
  size_t next = bytes->cap == 0 ? 256 : bytes->cap;
  while (next < required) {
    if (next > SIZE_MAX / 2) {
      next = required;
      break;
    }
    next *= 2;
  }
  void *allocation = realloc(bytes->data, next);
  if (allocation == NULL) return false;
  bytes->data = allocation;
  bytes->cap = next;
  return true;
}

static bool bytes_append(Bytes *bytes, const uint8_t *data, size_t len) {
  if (!bytes_reserve(bytes, len)) return false;
  if (len > 0) memcpy(bytes->data + bytes->len, data, len);
  bytes->len += len;
  return true;
}

static jbyteArray bytes_to_java(JNIEnv *env, Bytes *bytes, bool clear) {
  if (bytes->len > INT32_MAX) {
    throw_runtime(env, "native byte buffer exceeds JNI array limit");
    return NULL;
  }
  jbyteArray result = (*env)->NewByteArray(env, (jsize)bytes->len);
  if (result != NULL && bytes->len > 0) {
    (*env)->SetByteArrayRegion(env, result, 0, (jsize)bytes->len,
                              (const jbyte *)bytes->data);
  }
  if (clear) bytes->len = 0;
  return result;
}

static void on_write_pty(GhosttyTerminal terminal, void *userdata,
                         const uint8_t *data, size_t len) {
  (void)terminal;
  ZukoTerminal *state = userdata;
  if (state != NULL) (void)bytes_append(&state->replies, data, len);
}

static ZukoTerminal *from_handle(jlong handle) {
  return (ZukoTerminal *)(uintptr_t)handle;
}

static void terminal_free(ZukoTerminal *state) {
  if (state == NULL) return;
  ghostty_key_event_free(state->key_event);
  ghostty_key_encoder_free(state->encoder);
  ghostty_render_state_row_cells_free(state->cells);
  ghostty_render_state_row_iterator_free(state->rows);
  ghostty_render_state_free(state->render);
  ghostty_terminal_free(state->terminal);
  free(state->replies.data);
  free(state);
}

JNIEXPORT jlong JNICALL
Java_dev_adonm_zuko_terminal_GhosttyNative_nativeCreate(
    JNIEnv *env, jobject self, jint cols, jint rows, jlong scrollback) {
  (void)self;
  if (cols <= 0 || cols > UINT16_MAX || rows <= 0 || rows > UINT16_MAX ||
      scrollback < 0) {
    throw_runtime(env, "invalid terminal dimensions");
    return 0;
  }
  ZukoTerminal *state = calloc(1, sizeof(*state));
  if (state == NULL) {
    throw_runtime(env, "could not allocate terminal state");
    return 0;
  }
  GhosttyTerminalOptions options = {
      .cols = (uint16_t)cols,
      .rows = (uint16_t)rows,
      .max_scrollback = (size_t)scrollback,
  };
  if (ghostty_terminal_new(NULL, &state->terminal, options) != GHOSTTY_SUCCESS ||
      ghostty_render_state_new(NULL, &state->render) != GHOSTTY_SUCCESS ||
      ghostty_render_state_row_iterator_new(NULL, &state->rows) != GHOSTTY_SUCCESS ||
      ghostty_render_state_row_cells_new(NULL, &state->cells) != GHOSTTY_SUCCESS ||
      ghostty_key_encoder_new(NULL, &state->encoder) != GHOSTTY_SUCCESS ||
      ghostty_key_event_new(NULL, &state->key_event) != GHOSTTY_SUCCESS) {
    terminal_free(state);
    throw_runtime(env, "libghostty terminal initialization failed");
    return 0;
  }

  ghostty_terminal_set(state->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, state);
  ghostty_terminal_set(state->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                       (const void *)on_write_pty);
  uint64_t no_images = 0;
  ghostty_terminal_set(state->terminal,
                       GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
                       &no_images);
  return (jlong)(uintptr_t)state;
}

JNIEXPORT void JNICALL
Java_dev_adonm_zuko_terminal_GhosttyNative_nativeClose(
    JNIEnv *env, jobject self, jlong handle) {
  (void)env;
  (void)self;
  terminal_free(from_handle(handle));
}

JNIEXPORT jbyteArray JNICALL
Java_dev_adonm_zuko_terminal_GhosttyNative_nativeFeed(
    JNIEnv *env, jobject self, jlong handle, jbyteArray input) {
  (void)self;
  ZukoTerminal *state = from_handle(handle);
  if (state == NULL || input == NULL) {
    throw_runtime(env, "terminal is closed");
    return NULL;
  }
  const jsize len = (*env)->GetArrayLength(env, input);
  jbyte *data = (*env)->GetByteArrayElements(env, input, NULL);
  if (data == NULL) return NULL;
  state->replies.len = 0;
  ghostty_terminal_vt_write(state->terminal, (const uint8_t *)data, (size_t)len);
  (*env)->ReleaseByteArrayElements(env, input, data, JNI_ABORT);
  return bytes_to_java(env, &state->replies, true);
}

JNIEXPORT jbyteArray JNICALL
Java_dev_adonm_zuko_terminal_GhosttyNative_nativeResize(
    JNIEnv *env, jobject self, jlong handle, jint cols, jint rows,
    jint cell_width, jint cell_height) {
  (void)self;
  ZukoTerminal *state = from_handle(handle);
  if (state == NULL || cols <= 0 || cols > UINT16_MAX || rows <= 0 ||
      rows > UINT16_MAX || cell_width < 0 || cell_height < 0) {
    throw_runtime(env, "invalid terminal resize");
    return NULL;
  }
  state->replies.len = 0;
  const GhosttyResult result = ghostty_terminal_resize(
      state->terminal, (uint16_t)cols, (uint16_t)rows,
      (uint32_t)cell_width, (uint32_t)cell_height);
  if (result != GHOSTTY_SUCCESS) {
    throw_runtime(env, "libghostty resize failed");
    return NULL;
  }
  return bytes_to_java(env, &state->replies, true);
}

JNIEXPORT void JNICALL
Java_dev_adonm_zuko_terminal_GhosttyNative_nativeScroll(
    JNIEnv *env, jobject self, jlong handle, jint rows) {
  (void)env;
  (void)self;
  ZukoTerminal *state = from_handle(handle);
  if (state == NULL) return;
  GhosttyTerminalScrollViewport viewport = {
      .tag = GHOSTTY_SCROLL_VIEWPORT_DELTA,
      .value = {.delta = rows},
  };
  ghostty_terminal_scroll_viewport(state->terminal, viewport);
}

static bool append_cell(Bytes *output, GhosttyRenderStateRowCells cells) {
  uint8_t local[64];
  GhosttyBuffer grapheme = {.ptr = local, .cap = sizeof(local), .len = 0};
  GhosttyResult result = ghostty_render_state_row_cells_get(
      cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &grapheme);
  if (result == GHOSTTY_SUCCESS) {
    if (grapheme.len == 0) return bytes_append(output, (const uint8_t *)" ", 1);
    return bytes_append(output, local, grapheme.len);
  }
  if (result != GHOSTTY_OUT_OF_SPACE || grapheme.len == 0) return false;
  uint8_t *dynamic = malloc(grapheme.len);
  if (dynamic == NULL) return false;
  grapheme.ptr = dynamic;
  grapheme.cap = grapheme.len;
  result = ghostty_render_state_row_cells_get(
      cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &grapheme);
  const bool ok = result == GHOSTTY_SUCCESS &&
                  bytes_append(output, dynamic, grapheme.len);
  free(dynamic);
  return ok;
}

JNIEXPORT jbyteArray JNICALL
Java_dev_adonm_zuko_terminal_GhosttyNative_nativeSnapshot(
    JNIEnv *env, jobject self, jlong handle) {
  (void)self;
  ZukoTerminal *state = from_handle(handle);
  if (state == NULL) {
    throw_runtime(env, "terminal is closed");
    return NULL;
  }
  if (ghostty_render_state_update(state->render, state->terminal) != GHOSTTY_SUCCESS ||
      ghostty_render_state_get(state->render,
                               GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
                               &state->rows) != GHOSTTY_SUCCESS) {
    throw_runtime(env, "libghostty snapshot update failed");
    return NULL;
  }

  Bytes output = {0};
  bool first_row = true;
  while (ghostty_render_state_row_iterator_next(state->rows)) {
    if (!first_row && !bytes_append(&output, (const uint8_t *)"\n", 1)) goto oom;
    first_row = false;
    const size_t row_start = output.len;
    if (ghostty_render_state_row_get(state->rows,
                                     GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                                     &state->cells) != GHOSTTY_SUCCESS) {
      free(output.data);
      throw_runtime(env, "libghostty row snapshot failed");
      return NULL;
    }
    while (ghostty_render_state_row_cells_next(state->cells)) {
      if (!append_cell(&output, state->cells)) goto oom;
    }
    while (output.len > row_start && output.data[output.len - 1] == ' ') output.len--;
  }
  jbyteArray result = bytes_to_java(env, &output, false);
  free(output.data);
  return result;

oom:
  free(output.data);
  throw_runtime(env, "could not allocate terminal snapshot");
  return NULL;
}

static GhosttyKey android_key(jint key_code) {
  switch (key_code) {
    case 19: return GHOSTTY_KEY_ARROW_UP;
    case 20: return GHOSTTY_KEY_ARROW_DOWN;
    case 21: return GHOSTTY_KEY_ARROW_LEFT;
    case 22: return GHOSTTY_KEY_ARROW_RIGHT;
    case 61: return GHOSTTY_KEY_TAB;
    case 66: return GHOSTTY_KEY_ENTER;
    case 67: return GHOSTTY_KEY_BACKSPACE;
    case 92: return GHOSTTY_KEY_PAGE_UP;
    case 93: return GHOSTTY_KEY_PAGE_DOWN;
    case 111: return GHOSTTY_KEY_ESCAPE;
    case 112: return GHOSTTY_KEY_DELETE;
    case 122: return GHOSTTY_KEY_HOME;
    case 123: return GHOSTTY_KEY_END;
    case 124: return GHOSTTY_KEY_INSERT;
    case 131: return GHOSTTY_KEY_F1;
    case 132: return GHOSTTY_KEY_F2;
    case 133: return GHOSTTY_KEY_F3;
    case 134: return GHOSTTY_KEY_F4;
    case 135: return GHOSTTY_KEY_F5;
    case 136: return GHOSTTY_KEY_F6;
    case 137: return GHOSTTY_KEY_F7;
    case 138: return GHOSTTY_KEY_F8;
    case 139: return GHOSTTY_KEY_F9;
    case 140: return GHOSTTY_KEY_F10;
    case 141: return GHOSTTY_KEY_F11;
    case 142: return GHOSTTY_KEY_F12;
    default: return GHOSTTY_KEY_UNIDENTIFIED;
  }
}

JNIEXPORT jbyteArray JNICALL
Java_dev_adonm_zuko_terminal_GhosttyNative_nativeEncodeKey(
    JNIEnv *env, jobject self, jlong handle, jint key_code, jint modifiers,
    jbyteArray text) {
  (void)self;
  ZukoTerminal *state = from_handle(handle);
  if (state == NULL) {
    throw_runtime(env, "terminal is closed");
    return NULL;
  }
  ghostty_key_encoder_setopt_from_terminal(state->encoder, state->terminal);
  ghostty_key_event_set_action(state->key_event, GHOSTTY_KEY_ACTION_PRESS);
  ghostty_key_event_set_key(state->key_event, android_key(key_code));
  ghostty_key_event_set_mods(state->key_event, (GhosttyMods)modifiers);
  ghostty_key_event_set_consumed_mods(state->key_event, 0);
  ghostty_key_event_set_composing(state->key_event, false);

  jbyte *text_bytes = NULL;
  jsize text_len = 0;
  if (text != NULL) {
    text_len = (*env)->GetArrayLength(env, text);
    text_bytes = (*env)->GetByteArrayElements(env, text, NULL);
  }
  ghostty_key_event_set_utf8(state->key_event, (const char *)text_bytes,
                             (size_t)text_len);

  char local[128];
  size_t written = 0;
  GhosttyResult result = ghostty_key_encoder_encode(
      state->encoder, state->key_event, local, sizeof(local), &written);
  if (text_bytes != NULL)
    (*env)->ReleaseByteArrayElements(env, text, text_bytes, JNI_ABORT);

  Bytes output = {0};
  if (result == GHOSTTY_SUCCESS) {
    if (!bytes_append(&output, (const uint8_t *)local, written)) goto key_oom;
  } else if (result == GHOSTTY_OUT_OF_SPACE) {
    if (!bytes_reserve(&output, written)) goto key_oom;
    result = ghostty_key_encoder_encode(state->encoder, state->key_event,
                                        (char *)output.data, output.cap, &written);
    if (result != GHOSTTY_SUCCESS) {
      free(output.data);
      throw_runtime(env, "libghostty key encoding failed");
      return NULL;
    }
    output.len = written;
  } else {
    throw_runtime(env, "libghostty key encoding failed");
    return NULL;
  }
  jbyteArray encoded = bytes_to_java(env, &output, false);
  free(output.data);
  return encoded;

key_oom:
  free(output.data);
  throw_runtime(env, "could not allocate encoded key");
  return NULL;
}
