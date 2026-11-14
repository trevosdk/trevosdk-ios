# TrevoSDK for iOS

Experiments and event tracking for iOS apps on [Trevo](https://trevosdk.com). The same user
gets the same variant here as on the web, verified against the shared conformance corpus.
Swift, no dependencies, iOS 15+ (also visionOS and macOS).

```swift
.package(url: "https://github.com/trevosdk/trevosdk-ios", from: "0.1.1")
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

Development happens in the Trevo monorepo (`sdks/ios`); this repository is its published mirror.
