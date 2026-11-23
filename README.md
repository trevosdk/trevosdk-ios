# TrevoSDK for iOS

Experiments and event tracking for iOS apps on [Trevo](https://trevosdk.com). The same user
gets the same variant here as on the web, verified against the shared conformance corpus.
Swift, no dependencies, iOS 15+ (also visionOS and macOS).

```swift
.package(url: "https://github.com/trevosdk/trevosdk-ios", from: "0.1.4")
```

```swift
import TrevoSDK

let trevo = TrevoClient(options: TrevoOptions(apiKey: "tsk_live_..."))

await trevo.ready()
if trevo.getVariant("checkout-v2") == "treatment" {
    // alternate experience
}
let headline = trevo.getParameter("paywall.headline", default: "Subscribe")
trevo.track("checkout_started", properties: ["plan": "pro"])
```

Use a Mobile key. Config, identity and queued events persist across launches, config refreshes
on every foreground, and events flush in the background. Full docs:
[docs.trevosdk.com/install/ios](https://docs.trevosdk.com/install/ios).

## Text per language

A text parameter can hold one text per language. `getParameter` with a `String` default returns
the text for the language the app shows (`pt-BR` falls back to `pt`, never to `pt-PT`), or the
default when there is none. That language is the localization the app runs in, unless you pass
`TrevoOptions(apiKey:locale:)` or call `setLocale` where the app picks its own:

```swift
trevo.setLocale("pt-BR")  // the user picked Portuguese in the app's settings
trevo.setLocale(nil)      // back to TrevoOptions.locale, or the app's localization
```

## Remote paywall

`TrevoPaywall` (SwiftUI) and `TrevoPaywallViewController` (UIKit) show a paywall page Trevo publishes
from your repo, so its layout can change without an App Store release. The app keeps its own billing:
the page buys only through the functions you pass, and only plans `products` returned. Your current
paywall is the fallback, shown whenever no page can: none published yet, not downloaded yet, or the
page didn't draw within `readyTimeout` (5 seconds) of its script first talking to the app. Getting
the page's script running gets its own 8 seconds from opening, so a slow device or one with
VoiceOver on still shows it.

```swift
.sheet(isPresented: $showPaywall) {
    TrevoPaywall(
        client: trevo, id: "main",
        products: { try await billing.products() },  // [TrevoPaywallProduct]
        buy: { id in try await billing.purchase(id) },  // .purchased, .cancelled or .pending
        restore: { try await billing.restore() },  // .restored or .nothingToRestore
        links: ["terms": termsURL, "privacy": privacyURL]
    ) {
        PaywallScreen()  // your own paywall
    }
}
```

The paywall closes (`onClose`, by default the environment's `dismiss`) when the page asks, or after a
purchase or restore succeeds. Present it so the system can always dismiss it, in a sheet or a pushed
screen, not a full-screen cover with dismissal disabled: a page that never closes would trap the user.
Pages download in the background after each config refresh and are checked against their SHA-256
before they show. Each time your own paywall shows although Trevo named
a page, the SDK tracks `$paywall_fallback` with the reason. Each purchase made on the page is tracked
as `purchase` with the paywall and product and no value, so a test between versions of the page needs
no tracking code of yours. While a purchase or restore is open, a page that fails doesn't put your paywall over the
store sheet: the paywall closes if the purchase goes through, and shows your paywall if it doesn't.

iOS only (not macOS, tvOS or visionOS) and not in app extensions. The page runs in a `WKWebView` with
a content rule list that blocks every network load, a non-persistent data store, no navigation or new
windows, and WebRTC, location, sharing and camera access removed in every frame, child frames
included. Camera, microphone and motion requests are denied.

Development happens in the Trevo monorepo (`sdks/ios`); this repository is its published mirror.
