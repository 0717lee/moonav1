/* Test-only buffered file reader. The decoder remains entirely in MoonBit. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#ifdef _WIN32
#include <wchar.h>
#endif

static FILE *files[6];
static const char *suffixes[] = { ".obu", ".reference.yuv", ".avif", ".alpha.yuv", ".icc-input.rgba16", ".icc-output.rgba16" };

int moonav1_fixture_config(int index) {
  const char *p = getenv("MOONAV1_FIXTURE_CONFIG");
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

int moonav1_fixture_open(int kind) {
  if (kind < 0 || kind > 5 || files[kind]) return -1;
#ifdef _WIN32
  const wchar_t *prefix = _wgetenv(L"MOONAV1_FIXTURE_PREFIX");
  static const wchar_t *wide_suffixes[] = { L".obu", L".reference.yuv", L".avif", L".alpha.yuv", L".icc-input.rgba16", L".icc-output.rgba16" };
  if (!prefix) return -1;
  size_t length = wcslen(prefix) + wcslen(wide_suffixes[kind]) + 1;
  wchar_t *path = malloc(length * sizeof(wchar_t));
  if (!path) return -1;
  wcscpy(path, prefix);
  wcscat(path, wide_suffixes[kind]);
  files[kind] = _wfopen(path, L"rb");
#else
  const char *prefix = getenv("MOONAV1_FIXTURE_PREFIX");
  if (!prefix) return -1;
  size_t length = strlen(prefix) + strlen(suffixes[kind]) + 1;
  char *path = malloc(length);
  if (!path) return -1;
  strcpy(path, prefix);
  strcat(path, suffixes[kind]);
  files[kind] = fopen(path, "rb");
#endif
  free(path);
  return files[kind] ? kind : -1;
}

int moonav1_fixture_read(int kind) {
  if (kind < 0 || kind > 5 || !files[kind]) return -2;
  int value = fgetc(files[kind]);
  if (value == EOF && ferror(files[kind])) return -2;
  return value;
}

int moonav1_fixture_rewind(int kind) {
  if (kind < 0 || kind > 5 || !files[kind]) return -1;
  return fseek(files[kind], 0, SEEK_SET);
}

void moonav1_fixture_close(int kind) {
  if (kind >= 0 && kind < 6 && files[kind]) {
    fclose(files[kind]);
    files[kind] = NULL;
  }
}
