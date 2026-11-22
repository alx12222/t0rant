#include <Python/Python.h>
#include <string.h>
#include <stdlib.h>
#include "PyBridge.h"

static int t0_ready = 0;

int t0_py_init(const char *home, const char *search_paths, const char *boot_code) {
    if (t0_ready) return 0;
    PyStatus status;
    PyPreConfig pre;
    PyPreConfig_InitIsolatedConfig(&pre);
    pre.utf8_mode = 1;
    status = Py_PreInitialize(&pre);
    if (PyStatus_Exception(status)) return -1;

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 1;
    config.module_search_paths_set = 1;

    status = PyConfig_SetBytesString(&config, &config.home, home);
    if (PyStatus_Exception(status)) { PyConfig_Clear(&config); return -2; }

    char *paths = strdup(search_paths);
    char *save = NULL;
    for (char *p = strtok_r(paths, "\n", &save); p; p = strtok_r(NULL, "\n", &save)) {
        wchar_t *w = Py_DecodeLocale(p, NULL);
        if (w) { PyWideStringList_Append(&config.module_search_paths, w); PyMem_RawFree(w); }
    }
    free(paths);

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) return -3;

    int rc = PyRun_SimpleString(boot_code);
    PyEval_SaveThread();
    t0_ready = 1;
    return rc;
}

char *t0_py_call(const char *method, const char *arg1, const char *arg2) {
    if (!t0_ready) return strdup("Python is not initialized.\n");
    PyGILState_STATE g = PyGILState_Ensure();
    char *result = NULL;
    PyObject *main = PyImport_AddModule("__main__");
    PyObject *obj = main ? PyObject_GetAttrString(main, "_t0") : NULL;
    PyObject *ret = obj ? PyObject_CallMethod(obj, method, "ss", arg1 ? arg1 : "", arg2 ? arg2 : "") : NULL;
    if (ret) {
        const char *s = PyUnicode_AsUTF8(ret);
        result = strdup(s ? s : "");
        Py_DECREF(ret);
    } else {
        PyErr_Print();
        result = strdup("internal error in t0rant Python bridge\n");
    }
    Py_XDECREF(obj);
    PyGILState_Release(g);
    return result;
}
