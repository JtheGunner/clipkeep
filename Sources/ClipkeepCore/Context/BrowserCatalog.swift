import Foundation

/// Browsers whose current address can be read with Apple Events.
public enum BrowserCatalog {
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    private static let safari: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
    ]

    public static var bundleIDs: Set<String> { chromium.union(safari) }

    public static func isBrowser(_ bundleID: String) -> Bool { bundleIDs.contains(bundleID) }

    /// Returned by a script when the window is private or its mode is unknown.
    public static let privateMarker = "@@private"

    public static func isSafari(_ bundleID: String) -> Bool { safari.contains(bundleID) }

    /// AppleScript that returns the address of the front tab, an empty string without a window, or
    /// `privateMarker`. Chromium browsers are read only when the window is known to be normal;
    /// any error, including a missing `mode` property, counts as private. Safari offers no way to
    /// tell a private window apart, so it is read only when the user allowed it.
    public static func script(forBundleID bundleID: String) -> String? {
        if safari.contains(bundleID) {
            return """
                with timeout of 1 seconds
                    tell application id "\(bundleID)"
                        if (count of documents) is 0 then return ""
                        return URL of front document
                    end tell
                end timeout
                """
        }
        guard chromium.contains(bundleID) else { return nil }
        return """
            try
                with timeout of 1 seconds
                    tell application id "\(bundleID)"
                        if (count of windows) is 0 then return ""
                        if mode of front window is not "normal" then return "\(privateMarker)"
                        return URL of active tab of front window
                    end tell
                end timeout
            on error
                return "\(privateMarker)"
            end try
            """
    }
}
