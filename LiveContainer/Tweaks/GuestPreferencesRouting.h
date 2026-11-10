#ifndef LC_GUEST_PREFERENCES_ROUTING_H
#define LC_GUEST_PREFERENCES_ROUTING_H

#include <stdbool.h>
#include <string.h>

typedef enum {
    LCGuestPreferencesOriginalContainer,
    LCGuestPreferencesOwnContainer,
    LCGuestPreferencesParentContainer,
} LCGuestPreferencesContainer;

// Ordinary guests already store every non-Apple suite in their own container.
// Helpers must use that same location for shared suites, while keeping their
// standard defaults (their bundle identifier) in the extension subcontainer.
static inline LCGuestPreferencesContainer LCGuestPreferencesContainerForDomain(
    const char *domain, const char *guestIdentifier, bool hasParentContainer) {
    if (domain && (strncmp(domain, "com.apple.", 10) == 0 ||
                   strncmp(domain, "group.com.apple.", 16) == 0 ||
                   strncmp(domain, "systemgroup.com.apple.", 22) == 0)) {
        return LCGuestPreferencesOriginalContainer;
    }
    if (hasParentContainer && domain && domain[0] && guestIdentifier && guestIdentifier[0] &&
        strcmp(domain, guestIdentifier) != 0) {
        return LCGuestPreferencesParentContainer;
    }
    return LCGuestPreferencesOwnContainer;
}

#endif
