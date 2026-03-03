import Foundation
import Darwin

final class ConfigService: @unchecked Sendable {
    private let configURL: URL
    private let queue = DispatchQueue(label: "config.service.queue")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1

    var onConfigReload: ((Result<AppConfig, Error>) -> Void)?

    init(configURL: URL) {
        self.configURL = configURL
    }

    deinit {
        stopWatching()
    }

    func load() throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw ConfigError.missingConfig(configURL)
        }
        let data = try Data(contentsOf: configURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let config = try decoder.decode(AppConfig.self, from: data)
            try config.validate()
            return config
        } catch {
            if let configError = error as? ConfigError {
                throw configError
            }
            throw ConfigError.decode(error.localizedDescription)
        }
    }

    func ensureDefaultConfigIfMissing(defaultContents: Data) throws {
        let folder = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        guard !FileManager.default.fileExists(atPath: configURL.path) else {
            return
        }
        try defaultContents.write(to: configURL, options: .atomic)
    }

    func startWatching() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopWatching()

            self.descriptor = open(self.configURL.path, O_EVTONLY)
            guard self.descriptor >= 0 else { return }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: self.descriptor,
                eventMask: [.write, .rename, .delete],
                queue: self.queue
            )

            source.setEventHandler { [weak self] in
                guard let self else { return }
                do {
                    let config = try self.load()
                    self.onConfigReload?(.success(config))
                } catch {
                    self.onConfigReload?(.failure(error))
                }
            }

            source.setCancelHandler { [weak self] in
                guard let self else { return }
                if self.descriptor >= 0 {
                    close(self.descriptor)
                }
                self.descriptor = -1
            }

            self.source = source
            source.resume()
        }
    }

    func stopWatching() {
        if let source {
            source.cancel()
            self.source = nil
        }
    }
}
