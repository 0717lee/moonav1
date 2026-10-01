/* Test-only buffered file reader. The decoder remains entirely in MoonBit. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <stdint.h>
#ifndef _WIN32
#include <sys/types.h>
#endif
#ifdef _WIN32
#include <wchar.h>
#endif

static FILE *files[4];

int moonav1_container_config(int index) {
  const char *p = getenv("MOONAV1_CONTAINER_CONFIG");
  if (!p || index < 0) return -1;
  for (int i = 0; i < index; ++i) {
    p = strchr(p, ',');
    if (!p) return -1;
    ++p;
  }
  char *end;
  long value = strtol(p, &end, 10);
  if (end == p || value < 0 || value > INT_MAX || (*end && *end != ',')) return -1;
  return (int)value;
}

static const char *path_for(int kind) {
  switch (kind) {
    case 0: return "MOONAV1_CONTAINER_INPUT";
    case 1: return "MOONAV1_CONTAINER_REFERENCE";
    case 2: return "MOONAV1_CONTAINER_EXPECTATION";
    case 3: return "MOONAV1_CONTAINER_REJECTED";
    default: return NULL;
  }
}

int moonav1_container_open(int kind) {
  if (kind < 0 || kind >= 4 || files[kind]) return -1;
#ifdef _WIN32
  const wchar_t *name = NULL;
  static const wchar_t *names[] = {
    L"MOONAV1_CONTAINER_INPUT", L"MOONAV1_CONTAINER_REFERENCE",
    L"MOONAV1_CONTAINER_EXPECTATION", L"MOONAV1_CONTAINER_REJECTED"
  };
  name = _wgetenv(names[kind]);
  if (!name) return -1;
  files[kind] = _wfopen(name, L"rb");
#else
  const char *name = getenv(path_for(kind));
  if (!name) return -1;
  files[kind] = fopen(name, "rb");
#endif
  return files[kind] ? kind : -1;
}

int moonav1_container_read(int kind) {
  if (kind < 0 || kind >= 4 || !files[kind]) return -2;
  const int value = fgetc(files[kind]);
  if (value == EOF && ferror(files[kind])) return -2;
  return value;
}

int moonav1_container_seek(int kind, int64_t offset) {
  if (kind < 0 || kind >= 4 || !files[kind] || offset < 0) return -1;
#ifdef _WIN32
  return _fseeki64(files[kind], offset, SEEK_SET);
#else
  return fseeko(files[kind], (off_t)offset, SEEK_SET);
#endif
}

void moonav1_container_close(int kind) {
  if (kind >= 0 && kind < 4 && files[kind]) {
    fclose(files[kind]);
    files[kind] = NULL;
  }
}
