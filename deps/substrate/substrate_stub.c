#include <objc/runtime.h>

void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old) {
    if (old) *old = class_replaceMethod(_class, message, hook, NULL);
}

void MSHookFunction(void *symbol, void *hook, void **old) {}
