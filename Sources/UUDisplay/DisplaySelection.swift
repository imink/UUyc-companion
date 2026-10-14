import Foundation

enum DisplaySelection {
    enum Owner { case uu, rustDesk }
    struct Selection {
        let owner: Owner
        let config: DeviceConfig
    }

    static func choose(uu: DeviceConfig?, rustDesk: DeviceConfig?, current: Owner?) -> Selection? {
        let candidates: [Selection] = [(Owner.uu, uu), (Owner.rustDesk, rustDesk)].compactMap { owner, config in
            guard let config, config.kind != .computer, config.hasSize else { return nil }
            return Selection(owner: owner, config: config)
        }
        if let current, let selection = candidates.first(where: { $0.owner == current }) {
            return selection
        }
        return candidates.first
    }
}
