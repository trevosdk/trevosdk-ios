# TrevoSDK for iOS

Experiments and event tracking for iOS apps on [Trevo](https://trevosdk.com). The same user
gets the same variant here as on the web, verified against the shared conformance corpus.
Swift, no dependencies, iOS 15+ (also visionOS and macOS).

```swift
.package(url: "https://github.com/trevosdk/trevosdk-ios", from: "0.1.0")
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

Development happens in the Trevo monorepo (`sdks/ios`); this repository is its published mirror.
