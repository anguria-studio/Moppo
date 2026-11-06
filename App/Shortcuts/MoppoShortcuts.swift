import AppIntents

struct MoppoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetFreeSpaceIntent(),
            phrases: ["Get free space in \(.applicationName)"],
            shortTitle: "Free Space",
            systemImageName: "internaldrive"
        )
        AppShortcut(
            intent: GetTrashSizeIntent(),
            phrases: ["Get Trash size in \(.applicationName)"],
            shortTitle: "Trash Size",
            systemImageName: "trash"
        )
        AppShortcut(
            intent: GetSafeToRemoveSizeIntent(),
            phrases: ["Get Safe to Remove size in \(.applicationName)"],
            shortTitle: "Safe to Remove Size",
            systemImageName: "checkmark.shield"
        )
        AppShortcut(
            intent: ScanForCleanupItemsIntent(),
            phrases: ["Scan with \(.applicationName)"],
            shortTitle: "Scan for Cleanup Items",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: DeleteSafeToRemoveIntent(),
            phrases: ["Delete Safe to Remove items with \(.applicationName)"],
            shortTitle: "Delete Safe to Remove",
            systemImageName: "trash"
        )
    }
}
