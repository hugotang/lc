#include "../LiveContainer/Tweaks/GuestPreferencesRouting.h"
#include <assert.h>
#include <stdio.h>

static const char *resolvedContainer(const char *domain, const char *identifier,
                                     const char *ownContainer, const char *parentContainer) {
    switch (LCGuestPreferencesContainerForDomain(domain, identifier, parentContainer != NULL)) {
        case LCGuestPreferencesOriginalContainer: return "/system/preferences";
        case LCGuestPreferencesOwnContainer: return ownContainer;
        case LCGuestPreferencesParentContainer: return parentContainer;
    }
    assert(false);
    return NULL;
}

static void testAppAndHelpersShareSuites(void) {
    const char *parent = "/accounts/first";
    const char *appID = "org.example.app";
    const char *helperIDs[] = {"org.example.app.jit", "org.example.app.memory"};
    const char *helperContainers[] = {"/accounts/first/Extensions/jit", "/accounts/first/Extensions/memory"};
    // A suite need not use an App Group prefix, and an explicit parent-app
    // domain must also resolve to the parent's existing preferences.
    const char *suites[] = {"group.org.example.shared", "org.example.shared.settings", "SharedPreferences", appID};
    for (size_t suite = 0; suite < sizeof(suites) / sizeof(suites[0]); suite++) {
        const char *appPath = resolvedContainer(suites[suite], appID, parent, NULL);
        assert(strcmp(appPath, parent) == 0);
        for (size_t helper = 0; helper < sizeof(helperIDs) / sizeof(helperIDs[0]); helper++) {
            const char *helperPath = resolvedContainer(suites[suite], helperIDs[helper], helperContainers[helper], parent);
            assert(strcmp(helperPath, appPath) == 0);
            assert(strcmp(resolvedContainer(helperIDs[helper], helperIDs[helper], helperContainers[helper], parent),
                          helperContainers[helper]) == 0);
        }
    }
    // Two copies of the same app must continue to isolate their preference
    // files, including when their helpers use the same bundle and suite IDs.
    assert(strcmp(resolvedContainer(suites[0], helperIDs[0], "/accounts/second/Extensions/jit", "/accounts/second"),
                  parent) != 0);
}

static void testAppleDomainsKeepSystemRouting(void) {
    const char *domains[] = {"com.apple.UIKit", "group.com.apple.preferences", "systemgroup.com.apple.shared"};
    for (size_t domain = 0; domain < sizeof(domains) / sizeof(domains[0]); domain++) {
        assert(LCGuestPreferencesContainerForDomain(domains[domain], "org.example.app", false) ==
               LCGuestPreferencesOriginalContainer);
        assert(LCGuestPreferencesContainerForDomain(domains[domain], "org.example.app.helper", true) ==
               LCGuestPreferencesOriginalContainer);
    }
    // Similar third-party names must not escape the guest's container rules.
    assert(LCGuestPreferencesContainerForDomain("com.appleish.settings", "org.example.app.helper", true) ==
           LCGuestPreferencesParentContainer);
}

static void testMissingExtensionConfigurationKeepsOwnContainer(void) {
    assert(LCGuestPreferencesContainerForDomain("group.org.example.shared", "org.example.app.helper", false) ==
           LCGuestPreferencesOwnContainer);
    assert(LCGuestPreferencesContainerForDomain(NULL, "org.example.app.helper", true) ==
           LCGuestPreferencesOwnContainer);
    assert(LCGuestPreferencesContainerForDomain("", "org.example.app.helper", true) ==
           LCGuestPreferencesOwnContainer);
    assert(LCGuestPreferencesContainerForDomain("group.org.example.shared", NULL, true) ==
           LCGuestPreferencesOwnContainer);
    assert(LCGuestPreferencesContainerForDomain("group.org.example.shared", "", true) ==
           LCGuestPreferencesOwnContainer);
}

int main(void) {
    testAppAndHelpersShareSuites();
    testAppleDomainsKeepSystemRouting();
    testMissingExtensionConfigurationKeepsOwnContainer();
    puts("Guest preference routing tests passed (shared suites, private helper defaults, account isolation and Apple domains).");
    return 0;
}
