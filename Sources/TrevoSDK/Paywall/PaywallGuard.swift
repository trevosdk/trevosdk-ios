/// What the SDK adds to every page before loading it. Spec: docs/sdk/remote-paywall.md, "The guard".
enum PaywallGuard {
    /// Removes WebRTC, which opens connections no content policy or request hook sees, and the APIs
    /// iOS has no permission hook for (location, sharing).
    static let documentStartScript =
        "(function(){function k(o,n){try{Object.defineProperty(o,n,{value:undefined,writable:false,"
        + "configurable:false})}catch(e){}}k(window,'RTCPeerConnection');k(window,'webkitRTCPeerConnection');"
        + "k(window,'open');var p=window.Navigator&&Navigator.prototype;if(p){k(p,'geolocation');"
        + "k(p,'share');k(p,'canShare');k(p,'mediaDevices');k(p,'getUserMedia');k(p,'webkitGetUserMedia')}})();"

    static let policy =
        "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; "
        + "font-src data:; base-uri 'none'; form-action 'none'"

    static let markup =
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
        + "<meta http-equiv=\"x-dns-prefetch-control\" content=\"off\">"
        + "<script>\(documentStartScript)</script>"

    private static let doctype = Array("<!doctype".utf16)

    /// Right after a doctype at the very start, so the page keeps standards mode; else first.
    static func guarded(_ html: String) -> String {
        let units = Array(html.utf16)
        let at = insertionOffset(units)
        return String(decoding: units[..<at], as: UTF16.self) + markup
            + String(decoding: units[at...], as: UTF16.self)
    }

    static func insertionOffset(_ units: [UInt16]) -> Int {
        var index = units.first == 0xFEFF ? 1 : 0
        while index < units.count, [0x09, 0x0A, 0x0C, 0x0D, 0x20].contains(units[index]) {
            index += 1
        }
        guard index + doctype.count <= units.count,
            zip(units[index..<index + doctype.count], doctype).allSatisfy({ asciiLower($0) == $1 }),
            let end = units[(index + doctype.count)...].firstIndex(of: 0x3E)
        else { return 0 }
        return end + 1
    }

    private static func asciiLower(_ unit: UInt16) -> UInt16 {
        (0x41...0x5A).contains(unit) ? unit + 0x20 : unit
    }
}
