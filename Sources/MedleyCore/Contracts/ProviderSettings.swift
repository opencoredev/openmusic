import SwiftUI

extension EnvironmentValues {
    /// The service's name, set by the Mac's Settings › Accounts on each provider's settings view. The first section's
    /// header (`ProviderSettingsHeader`) carries it, so one heading sits over the service's sections without an
    /// empty section of its own (which left a double gap above it).
    @Entry public var providerSettingsTitle: String? = nil
}

/// The header of a provider's first settings section: the service's name when Settings › Accounts set one
/// (`providerSettingsTitle`), then the section's own name, if any.
public struct ProviderSettingsHeader: View {
    let subtitle: String?
    @Environment(\.providerSettingsTitle) private var title

    public init(_ subtitle: String? = nil) { self.subtitle = subtitle }

    public var body: some View {
        if title != nil || subtitle != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).font(.headline).foregroundStyle(.primary) }
                if let subtitle { Text(subtitle) }
            }
        }
    }
}
