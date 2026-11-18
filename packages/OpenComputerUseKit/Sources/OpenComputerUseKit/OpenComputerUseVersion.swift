import Foundation

/// Bundled builds report the version stamped by the packager.
public let openComputerUseVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.4"
