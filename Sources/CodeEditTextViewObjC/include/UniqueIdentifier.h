//
//  UniqueIdentifier.h
//  CodeEditTextViewObjC
//

#ifndef UniqueIdentifier_h
#define UniqueIdentifier_h

#include <stdint.h>

/// Returns a process-unique, monotonically increasing value. One relaxed atomic add, no lock.
///
/// Backs the identifiers of hot object types (`TextLine`, `LineFragment`), where `UUID()`'s trip to the
/// system random number generator (~230ns) dominated construction cost.
uint64_t CETVNextUniqueIdentifier(void);

#endif /* UniqueIdentifier_h */
