import Foundation

/// A model package available in the Hugging Face repo.
public struct RemoteModel: Sendable, Equatable, Identifiable {
    public struct File: Sendable, Equatable {
        /// Path inside the repo, e.g. `yolo26x-seg.mlpackage/Manifest.json`.
        public var path: String
        public var size: Int64
        /// SHA-256 for LFS files; small files stored in git have none.
        public var sha256: String?

        public init(path: String, size: Int64, sha256: String?) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    public var stem: String
    public var files: [File]
    public var id: String { stem }
    public var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public enum HuggingFaceError: Error, LocalizedError {
    case notConfigured
    case invalidToken
    case noAccess(String)
    case http(Int, String)
    case modelNotAvailable(String, repo: String)
    case sizeMismatch(String)
    case checksumMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Set your Hugging Face username in Settings → Hugging Face first."
        case .invalidToken:
            return "Hugging Face didn't accept the token. Paste a fresh one from huggingface.co/settings/tokens."
        case .noAccess(let repo):
            return "Hugging Face repo \(repo) wasn't found, or the token can't read it. Check the username, repository and token in Settings."
        case .http(let status, let url):
            return "Hugging Face answered HTTP \(status) for \(url)."
        case .modelNotAvailable(let stem, let repo):
            return "\(stem) isn't in the Hugging Face repo \(repo)."
        case .sizeMismatch(let path):
            return "\(path) downloaded with the wrong size. Try again."
        case .checksumMismatch(let path):
            return "\(path) failed its checksum. Try again."
        }
    }
}

/// Lists and downloads model packages from a Hugging Face model repo. Each
/// `.mlpackage` is stored in the repo as a plain folder, so a download is just
/// its files fetched one by one and checked against the repo's own sizes and
/// SHA-256s.
public struct HuggingFaceClient: Sendable {
    public static let host = URL(string: "https://huggingface.co")!

    public var source: ModelSource
    public var token: String?
    public var revision: String

    public init(source: ModelSource, token: String?, revision: String = "main") {
        self.source = source
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.revision = revision
    }

    /// The account the token belongs to.
    public func whoami() async throws -> String {
        struct WhoAmI: Decodable { let name: String }
        let url = Self.host.appendingPathComponent("api/whoami-v2")
        let (data, response) = try await URLSession.shared.data(for: request(url))
        try check(response, url: url, accessError: .invalidToken)
        return try JSONDecoder().decode(WhoAmI.self, from: data).name
    }

    /// Every top-level `.mlpackage` in the repo.
    public func listModels() async throws -> [RemoteModel] {
        guard let repo = source.repoID else { throw HuggingFaceError.notConfigured }
        var next: URL? = URL(string: "\(Self.host.absoluteString)/api/models/\(repo)/tree/\(revision)?recursive=true")
        var entries: [TreeEntry] = []
        while let url = next {
            let (data, response) = try await URLSession.shared.data(for: request(url))
            try check(response, url: url, accessError: .noAccess(repo))
            entries += try JSONDecoder().decode([TreeEntry].self, from: data)
            next = (response as? HTTPURLResponse).flatMap { Self.nextPage(linkHeader: $0.value(forHTTPHeaderField: "Link")) }
        }
        return Self.models(from: entries)
    }

    /// Download a package into the store. Files land in a staging folder and
    /// the package is moved into place only once every file checks out.
    /// `progress` gets the completed fraction, 0…1.
    @discardableResult
    public func download(
        _ model: RemoteModel,
        into store: ModelStore,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let repo = source.repoID else { throw HuggingFaceError.notConfigured }
        let fm = FileManager.default
        let staging = try store.makeStagingDirectory()
        defer { try? fm.removeItem(at: staging) }

        let meter = ProgressMeter(total: model.bytes, report: progress)
        let downloader = FileDownloader(repo: repo)
        defer { downloader.invalidate() }

        for file in model.files {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await downloader.download(request(fileURL(repo: repo, path: file.path)), to: destination) { bytes in
                meter.add(bytes)
            }
            try Self.verify(file, at: destination)
        }
        let package = staging.appendingPathComponent("\(model.stem).\(ModelStore.packageExtension)")
        return try store.install(staged: package, stem: model.stem)
    }

    // MARK: - Helpers

    /// Size first (cheap), then SHA-256 when the repo gives one.
    public static func verify(_ file: RemoteModel.File, at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size == file.size else { throw HuggingFaceError.sizeMismatch(file.path) }
        if let expected = file.sha256, try Hasher.sha256(ofFileAt: url) != expected.lowercased() {
            throw HuggingFaceError.checksumMismatch(file.path)
        }
    }

    struct TreeEntry: Decodable {
        struct LFS: Decodable {
            let oid: String
            let size: Int64
        }
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?
    }

    /// Group a recursive tree listing into packages. Anything outside a
    /// top-level `.mlpackage` folder (README, .gitattributes…) is ignored.
    public static func models(fromTree data: Data) throws -> [RemoteModel] {
        models(from: try JSONDecoder().decode([TreeEntry].self, from: data))
    }

    static func models(from entries: [TreeEntry]) -> [RemoteModel] {
        var files: [String: [RemoteModel.File]] = [:]
        for entry in entries where entry.type == "file" {
            let parts = entry.path.split(separator: "/", maxSplits: 1)
            guard parts.count == 2, parts[0].hasSuffix(".\(ModelStore.packageExtension)") else { continue }
            let stem = String(parts[0].dropLast(ModelStore.packageExtension.count + 1))
            files[stem, default: []].append(RemoteModel.File(
                path: entry.path,
                size: entry.lfs?.size ?? entry.size ?? 0,
                sha256: entry.lfs?.oid
            ))
        }
        return files
            .map { RemoteModel(stem: $0.key, files: $0.value.sorted { $0.path < $1.path }) }
            .sorted { ModelCatalog.sortKey(for: $0.stem) < ModelCatalog.sortKey(for: $1.stem) }
    }

    /// `<https://…>; rel="next"` from a paginated listing.
    static func nextPage(linkHeader: String?) -> URL? {
        guard let linkHeader else { return nil }
        for part in linkHeader.split(separator: ",") where part.contains("rel=\"next\"") {
            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end else { continue }
            return URL(string: String(part[part.index(after: start)..<end]))
        }
        return nil
    }

    private func fileURL(repo: String, path: String) -> URL {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "\(Self.host.absoluteString)/\(repo)/resolve/\(revision)/\(encoded)")!
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("HumanDetector", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func check(_ response: URLResponse, url: URL, accessError: HuggingFaceError) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403, 404: throw accessError
        default: throw HuggingFaceError.http(http.statusCode, url.absoluteString)
        }
    }
}

/// Adds up bytes from every file and reports the fraction, at most every 0.5%.
private final class ProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private let report: @Sendable (Double) -> Void
    private var done: Int64 = 0
    private var lastStep = -1

    init(total: Int64, report: @escaping @Sendable (Double) -> Void) {
        self.total = max(total, 1)
        self.report = report
    }

    func add(_ bytes: Int64) {
        let fraction: Double? = lock.withLock {
            done += bytes
            let value = min(1, Double(done) / Double(total))
            let step = Int(value * 200)
            guard step != lastStep else { return nil }
            lastStep = step
            return value
        }
        if let fraction { report(fraction) }
    }
}

/// One file at a time on its own session, so progress comes per chunk and
/// the transfer can be cancelled. The token is only sent to huggingface.co:
/// file bodies redirect to a CDN with a signed URL that rejects extra auth.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let repo: String
    private let lock = NSLock()
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var onBytes: ((Int64) -> Void)?
    private var failure: Error?

    init(repo: String) {
        self.repo = repo
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    /// The session holds its delegate strongly; this breaks the cycle.
    func invalidate() {
        session.invalidateAndCancel()
    }

    func download(_ request: URLRequest, to destination: URL, onBytes: @escaping (Int64) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                lock.withLock {
                    self.continuation = continuation
                    self.destination = destination
                    self.onBytes = onBytes
                    self.failure = nil
                    let task = session.downloadTask(with: request)
                    self.task = task
                    task.resume()
                }
            }
        } onCancel: {
            lock.withLock { task }?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.withLock { onBytes }?(bytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so move it now.
        let destination = lock.withLock { self.destination }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let error: Error = [401, 403, 404].contains(http.statusCode)
                ? HuggingFaceError.noAccess(repo)
                : HuggingFaceError.http(http.statusCode, downloadTask.originalRequest?.url?.absoluteString ?? "")
            lock.withLock { failure = error }
            return
        }
        guard let destination else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { failure = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, failure) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?) in
            let pending = self.continuation
            self.continuation = nil
            self.task = nil
            return (pending, self.failure)
        }
        if let error = error as? URLError, error.code == .cancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let error = error ?? failure {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        if request.url?.host != HuggingFaceClient.host.host {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }
}
