// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct ConfigStore: Sendable {
    public let projectDirectory: URL

    public init(projectDirectory: URL) {
        self.projectDirectory = projectDirectory.standardizedFileURL
    }

    public var configurationURL: URL {
        projectDirectory.appendingPathComponent("yagarto.json", isDirectory: false)
    }

    public func load() throws -> ProjectConfiguration {
        let data: Data
        do {
            data = try Data(contentsOf: configurationURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw YagartoError.configurationNotFound(configurationURL.path)
        } catch {
            throw YagartoError.configurationIOFailed(
                configurationURL.path,
                error.localizedDescription
            )
        }

        let configuration: ProjectConfiguration
        do {
            configuration = try JSONDecoder().decode(ProjectConfiguration.self, from: data)
        } catch {
            throw YagartoError.corruptedConfiguration(error.localizedDescription)
        }

        try Self.validate(configuration)
        return configuration
    }

    public func save(_ configuration: ProjectConfiguration) throws {
        try Self.validate(configuration)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(configuration)
            data.append(0x0A)
            try data.write(to: configurationURL, options: .atomic)
        } catch {
            throw YagartoError.configurationIOFailed(
                configurationURL.path,
                error.localizedDescription
            )
        }
    }

    public static func validate(_ configuration: ProjectConfiguration) throws {
        guard configuration.schemaVersion == 1 else {
            throw YagartoError.unsupportedSchemaVersion(configuration.schemaVersion)
        }
        guard !configuration.sources.isEmpty else {
            throw YagartoError.emptySources
        }

        for source in configuration.sources {
            if NSString(string: source).isAbsolutePath {
                throw YagartoError.absoluteSourcePath(source)
            }
            if pathComponents(of: source).contains("..") {
                throw YagartoError.pathTraversal(source)
            }
            guard source.hasSuffix(".s") || source.hasSuffix(".S") else {
                throw YagartoError.invalidSourceExtension(source)
            }
        }

        let outputComponents = pathComponents(of: configuration.outputName)
        guard !configuration.outputName.isEmpty,
              !NSString(string: configuration.outputName).isAbsolutePath,
              outputComponents.count == 1,
              outputComponents.first != ".." else {
            throw YagartoError.invalidOutputName(configuration.outputName)
        }
    }

    private static func pathComponents(of path: String) -> [String] {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
    }
}
