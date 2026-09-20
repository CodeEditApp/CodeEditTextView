//
//  UniqueIdentifier.c
//  CodeEditTextViewObjC
//

#include "UniqueIdentifier.h"
#include <stdatomic.h>

// Starts at 1 so zero can serve as "no identifier" if a caller ever needs it.
static _Atomic uint64_t counter = 1;

uint64_t CETVNextUniqueIdentifier(void) {
    return atomic_fetch_add_explicit(&counter, 1, memory_order_relaxed);
}
