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

    /// AppleScript that returns the address of the front tab, or an empty string. Private
    /// windows of Chromium browsers are not read. The script ends quickly when the browser hangs.
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
            with timeout of 1 seconds
                tell application id "\(bundleID)"
                    if (count of windows) is 0 then return ""
                    set windowMode to ""
                    try
                        set windowMode to mode of front window
                    end try
                    if windowMode is "incognito" then return ""
                    return URL of active tab of front window
                end tell
            end timeout
            """
    }
}
