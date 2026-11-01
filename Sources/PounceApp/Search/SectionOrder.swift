import PounceKit

/// The user-defined order of result sections (issue #5, spec: Model pluginów → Kolejność), stored as
/// plugin ids in `app.sectionOrder`. Ids in the saved order come first, in that order; every other
/// plugin follows in `manifest.order`. Unknown ids are ignored, so a removed plugin never breaks it.
enum SectionOrder {
    static func sorted(_ entries: [PluginHost.Entry], saved: [String]) -> [PluginHost.Entry] {
        let ids = sorted(entries.map(\.manifest.id), saved: saved)
        return ids.compactMap { id in entries.first { $0.manifest.id == id } }
    }

    /// `ids` must already be in `manifest.order`.
    static func sorted(_ ids: [PluginID], saved: [String]) -> [PluginID] {
        var result: [PluginID] = []
        for raw in saved {
            let id = PluginID(rawValue: raw)
            if ids.contains(id), !result.contains(id) {
                result.append(id)
            }
        }
        result.append(contentsOf: ids.filter { !result.contains($0) })
        return result
    }

    /// The order after moving `id` one place up (`offset` −1) or down (+1) among `ids` (the plugins
    /// with result sections, already in their current order). Returns the full list to save.
    static func moving(_ id: PluginID, by offset: Int, in ids: [PluginID]) -> [PluginID] {
        guard let index = ids.firstIndex(of: id) else { return ids }
        let target = index + offset
        guard ids.indices.contains(target) else { return ids }
        var result = ids
        result.swapAt(index, target)
        return result
    }
}
