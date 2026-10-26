import Foundation

/// The host of the server's public links: the self-hosted counterpart of `t.me`. The client parses
/// links on this host as internal links and builds every shareable link on it.
public let telesrvLinkHost = "darkmoon.cc"

/// The URL scheme of the server's app links: the counterpart of `tg`. Links that leave the app use
/// it; inside the app they are rewritten to `tg://` (`telesrvInternalUrl`) so the existing `tg://`
/// handling applies unchanged.
public let telesrvUrlScheme = "dm"

/// Rewrites a `dm://` link to the `tg://` form the app's link handling understands. Any other URL
/// is returned unchanged.
public func telesrvInternalUrl(_ url: String) -> String {
    let prefix = "\(telesrvUrlScheme)://"
    if url.count >= prefix.count, url.prefix(prefix.count).lowercased() == prefix {
        return "tg://" + url.dropFirst(prefix.count)
    }
    return url
}

/// `telesrvInternalUrl(_:)` for a `URL`.
public func telesrvInternalUrl(_ url: URL) -> URL {
    if url.scheme?.lowercased() == telesrvUrlScheme {
        return URL(string: telesrvInternalUrl(url.absoluteString)) ?? url
    }
    return url
}

/// Whether `url` is an app link: `tg://` or this app's `dm://`.
public func isTelesrvAppSchemeUrl(_ url: String) -> Bool {
    let lowercased = url.lowercased()
    return lowercased.hasPrefix("tg://") || lowercased.hasPrefix("\(telesrvUrlScheme)://")
}
