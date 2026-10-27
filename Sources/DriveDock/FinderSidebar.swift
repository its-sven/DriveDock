import CoreServices
import Foundation

/// Finder sidebar "Favoriten" via LSSharedFileList. The API is deprecated but still the
/// only way to do this; note that kLSSharedFileListItemLast crashes on current macOS,
/// so new items are inserted after the last existing one.
enum FinderSidebar {
    private static func favorites() -> LSSharedFileList? {
        LSSharedFileListCreate(nil, kLSSharedFileListFavoriteItems.takeUnretainedValue(), nil)?.takeRetainedValue()
    }

    /// Resolving a favorite must never mount a volume or show UI: an old entry may point to
    /// a share whose server is offline, and this runs on the main thread.
    private static let resolveFlags = LSSharedFileListResolutionFlags(
        kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)

    private static func items(of list: LSSharedFileList) -> [LSSharedFileListItem] {
        var seed: UInt32 = 0
        return (LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem]) ?? []
    }

    static func contains(_ url: URL) -> Bool {
        guard let list = favorites() else { return false }
        let target = url.standardizedFileURL.path
        return items(of: list).contains { item in
            let resolved = LSSharedFileListItemCopyResolvedURL(item, resolveFlags, nil)?.takeRetainedValue() as URL?
            return resolved?.standardizedFileURL.path == target
        }
    }

    @discardableResult
    static func add(_ url: URL) -> Bool {
        guard let list = favorites(), !contains(url), let last = items(of: list).last else { return false }
        return LSSharedFileListInsertItemURL(list, last, nil, nil, url as CFURL, nil, nil) != nil
    }

    static func remove(_ url: URL) {
        guard let list = favorites() else { return }
        let target = url.standardizedFileURL.path
        for item in items(of: list) {
            let resolved = LSSharedFileListItemCopyResolvedURL(item, resolveFlags, nil)?.takeRetainedValue() as URL?
            if resolved?.standardizedFileURL.path == target {
                LSSharedFileListItemRemove(list, item)
            }
        }
    }

    // Remembers which connections already got their entry, so one the user removed stays removed.
    private static let addedKey = "sidebarConnectionIDs"

    /// Tries once per profile. Even if adding fails (e.g. an empty favorites list), the
    /// attempt is recorded, so it isn't retried on every reconnect.
    static func addOnce(_ url: URL, for id: UUID) {
        var added = Set(UserDefaults.standard.stringArray(forKey: addedKey) ?? [])
        guard !added.contains(id.uuidString) else { return }
        if !contains(url) { add(url) }
        added.insert(id.uuidString)
        UserDefaults.standard.set(Array(added), forKey: addedKey)
    }

    static func forget(_ id: UUID) {
        let added = (UserDefaults.standard.stringArray(forKey: addedKey) ?? []).filter { $0 != id.uuidString }
        UserDefaults.standard.set(added, forKey: addedKey)
    }

    /// Versions up to 0.2 put the mounted volumes themselves into the sidebar. Those
    /// bookmarks follow the volume and show up as "EDV". Removes every entry below the
    /// root except the root itself, once, so the profile folders can be added instead.
    static func migrateToProfileFolders(root: URL) {
        let key = "sidebarLayoutVersion"
        guard UserDefaults.standard.integer(forKey: key) < 2, let list = favorites() else { return }
        let rootPath = root.standardizedFileURL.path
        for item in items(of: list) {
            guard let path = (LSSharedFileListItemCopyResolvedURL(item, resolveFlags, nil)?.takeRetainedValue() as URL?)?
                .standardizedFileURL.path else { continue }
            if path.hasPrefix(rootPath + "/") {
                LSSharedFileListItemRemove(list, item)
            }
        }
        UserDefaults.standard.removeObject(forKey: addedKey)
        UserDefaults.standard.set(2, forKey: key)
    }

    /// Adds the folder once; if the user removes it later, it stays removed.
    static func addOnFirstLaunch(_ url: URL) {
        let key = "didAddSidebarFavorite"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        if contains(url) || add(url) {
            UserDefaults.standard.set(true, forKey: key)
        }
    }
}
