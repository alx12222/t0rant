#ifndef PYBRIDGE_H
#define PYBRIDGE_H
/// Thin C wrapper around the embedded CPython interpreter so Swift never touches Python.h.
int t0_py_init(const char *home, const char *search_paths, const char *boot_code);
/// Calls _t0.<method>(arg1, arg2) and returns a malloc'd UTF-8 string (caller frees).
char *t0_py_call(const char *method, const char *arg1, const char *arg2);
#endif
