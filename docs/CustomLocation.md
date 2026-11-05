# Custom Location (3.8.36)

Open an app's Settings → **Custom Location**. This is a built-in option: the settings UI uses MapKit and the guest bootstrap installs the location module from LiveContainerShared before loading guest initializers. No separate dylib installation is required.

The setting is off by default. Turn it on to select a location, or choose a location first and enable it later. Search for an address or place, select a result, long-press the map, drag its pin, select the map center, or enter decimal latitude/longitude. Search results never select themselves. **Use This Location** commits the selection; Cancel preserves the saved value. Address search and map imagery need a network connection; coordinate entry does not. The picker does not request device location permission or display the user's real location.

Coordinates use WGS 84 decimal degrees, latitude first (−90…90) and longitude second (−180…180). Negative values represent south/west. Decimal commas are accepted in the separate numeric fields. Empty, nonnumeric, nonfinite and out-of-range values cannot be saved; `(0, 0)` is a valid deliberate selection. The saved point includes a short optional place name. Search queries/results are not persisted.

One position is stored per app in `LCAppInfo.plist`, shared by its accounts. Saving writes coordinates and enabled state together. Disabling retains the point. Close and reopen all accounts after changing either the switch or position: each guest captures its own configuration at launch. Ordinary launches, virtual multitasking and native LiveProcess windows use the same bootstrap gate. TweakLoader injection must be enabled. SideStore and 32-bit translated apps are excluded; the host's settings map never installs the guest hook.

## Runtime contract

The first version supports the standard `CLLocationManager` delegate interface: `requestLocation`, `startUpdatingLocation`/`stopUpdatingLocation`, significant-change start/stop, and the `location` property. Managers created after installation have a retained proxy with weak references to the manager and the original delegate. Other delegate events are forwarded. Instances that predate installation retain their original behavior.

Authorization requests, status, precision authorization and system Location Services are not spoofed. A request waits while permission is undetermined and produces no coordinate. Denied/restricted permission or disabled services returns the normal denied error to the delegate; the location property is nil. The guest must request location access as it normally would. No permission descriptions or entitlements are inserted into guest bundles.

The covered requests do not start real sensor updates. Authorized one-shot requests asynchronously publish one fixed location on the manager's creation run loop. Continuous updates with no positive distance filter publish at most once per second using a timer with tolerance; stop cancels pending deliveries and the timer. A positive distance filter or stationary significant-change subscription receives an initial sample without idle periodic traffic. Changing the distance filter refreshes this policy. Significant-change monitoring does not arrange OS wakeups or background execution.

Samples have a fresh timestamp, 5 m horizontal accuracy, zero speed, and unknown altitude accuracy/course. They are marked as software-simulated through `CLLocationSourceInformation`. The last-location property returns the same delivered sample while authorized. The module does not override `CLLocation.coordinate` or constructors: independently created locations such as map destinations keep their original values. It is not an anti-detection feature.

This version does not cover WebKit's separate-process geolocation, newer Swift async location APIs (`CLLocationUpdate`), region/beacon monitoring, visit events, heading, IP-based location or background wakeups. Those retain system behavior. This is a compatibility/testing option, not a guarantee that every source of location in an app is replaced.

## Validation

The simulator suite exercises the production hook against a manager double to control authorization without touching system permissions. It checks saved-setting validation, opt-in gating, asynchronous one-shot delivery, unchanged ordinary CLLocation objects, permission changes, distance filtering, timer cancellation, delegate replacement, weak lifetimes, legacy callbacks, multiple managers and suppression of covered late system samples. A separate test uses a real CLLocationManager subclass with only authorization controlled, checking initialization, delegate storage and one-shot delivery. The iPhone/iPad UI suite runs the production picker, checks cancellation, zero/negative coordinates, validation and saved selections, and exports screenshots. Full compilation and existing window/input tests run in CI.

Device acceptance must additionally verify real Core Location behavior on an iPhone and iPad in ordinary, virtual and native launches; both permission choices; one and multiple accounts; settings upgrade/persistence; background/foreground; and the intended app's actual response. Simulator doubles do not establish private hosting behavior or game compatibility.
