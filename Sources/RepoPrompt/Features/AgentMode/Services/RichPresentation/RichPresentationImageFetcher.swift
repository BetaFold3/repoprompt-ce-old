import Foundation
import RepoPromptAgentCore

// SEARCH-HELPER: rich presentation article image fetch, approved image hosts, image phase deadline

/// One article image result: the stored terminal outcome plus, for an asset, the normalized JPEG
/// bytes Step 3 stores under the asset ID. Neither part contains the request URL or its query.
struct RichPresentationFetchedImage: Equatable {
    let outcome: RichPresentationArticleImageOutcome
    let jpegData: Data?
}

/// Bounded, isolated acquisition of optional briefing article images
/// (docs/context/specs/2026-11-04-rich-presentation-spec.md, "Article image boundary" and A5).
///
/// - Only explicitly supplied URLs on exact approved hosts are requested, byte-for-byte as supplied;
///   the query lives only in the request. Outcomes record the sanitized origin or a failure code.
/// - A dedicated ephemeral session: no cookies, credential storage, cache, Authorization, Referer,
///   workspace identifiers or agent-selected headers; normal TLS verification, every other
///   authentication challenge cancelled, every redirect refused, HTTP 200 only.
/// - Bounds: per-image and per-artifact streamed (decompressed) bytes, one image-phase deadline,
///   and, through `shared`, two downloads and one native decode app-wide. A download permit belongs
///   to the URLSession transfer and returns only at its terminal callback; a native decode keeps its
///   permit until it actually ends. Both hold even when their caller was cancelled.
/// - It never logs. Failures are terminal per image and never affect article text. After
///   `fetchImages` returns or throws, the only remaining work is cancelled transfers that are still
///   stopping, each holding its download permit until URLSession's terminal callback, and a
///   discarded decode that already holds its permit. Neither produces a result.
///
/// It trusts approved hosts and the Mac's DNS/TLS/proxy routing; it does not confine destinations
/// to public addresses.
final class RichPresentationImageFetcher: @unchecked Sendable {
    typealias Decoder = @Sendable (_ data: Data, _ mimeType: String?, _ limits: RichPresentationImageLimits)
        -> Result<RichPresentationNormalizedImage, RichPresentationImageFailureCode>

    static let maxConcurrentDownloads = 2
    static let maxConcurrentDecodes = 1

    /// App-wide instance; its permit pools are the app-wide download and decode bounds.
    static let shared = RichPresentationImageFetcher()

    private let session: URLSession
    private let limits: RichPresentationImageLimits
    private let decode: Decoder
    private let downloadPermits: RichPresentationPermitPool
    private let decodePermits: RichPresentationPermitPool

    init(
        configuration: URLSessionConfiguration = RichPresentationImageFetcher.makeConfiguration(),
        limits: RichPresentationImageLimits = .standard,
        delegateQueue: OperationQueue? = nil,
        decode: @escaping Decoder = { RichPresentationImageNormalizer.normalize(data: $0, mimeType: $1, limits: $2) }
    ) {
        session = URLSession(
            configuration: configuration,
            delegate: RichPresentationImageRequestPolicy.shared,
            delegateQueue: delegateQueue
        )
        self.limits = limits
        self.decode = decode
        downloadPermits = RichPresentationPermitPool(permits: Self.maxConcurrentDownloads)
        decodePermits = RichPresentationPermitPool(permits: Self.maxConcurrentDecodes)
    }

    deinit {
        // A session retains its delegate until invalidated.
        session.invalidateAndCancel()
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpAdditionalHeaders = nil
        config.waitsForConnectivity = false
        // Backstops only; the image-phase deadline is enforced per request and per publication.
        let deadline = TimeInterval(RichPresentationImageLimits.standard.imagePhaseDeadline.components.seconds)
        config.timeoutIntervalForRequest = deadline
        config.timeoutIntervalForResource = deadline
        return config
    }

    /// Fetches and normalizes every image request of a validated input, returning one terminal
    /// result per `input.imageSlots` entry in the same order. Requests still unfinished when the
    /// image-phase deadline passes become `deadline`. Throws only `CancellationError`, when the
    /// calling task (the publication) is cancelled.
    func fetchImages(for input: RichPresentationInput, approvedHosts: [String]) async throws -> [RichPresentationFetchedImage] {
        try Task.checkCancellation()
        let slots = input.imageSlots
        guard !slots.isEmpty else { return [] }

        let hosts = Set(approvedHosts)
        let deadline = ContinuousClock.now + limits.imagePhaseDeadline
        let budget = RichPresentationByteBudget(limit: limits.maxArtifactBytes)
        var results = [RichPresentationFetchedImage?](repeating: nil, count: slots.count)
        var admitted: [(index: Int, url: URL, origin: String)] = []
        for (index, slot) in slots.enumerated() {
            switch RichPresentationURLPolicy.evaluateImageURL(slot.request.url, approvedHosts: hosts) {
            case let .failure(code):
                results[index] = Self.failed(slot, code)
            case let .success(url):
                guard let origin = RichPresentationImageAsset.sanitizedOrigin(of: url) else {
                    results[index] = Self.failed(slot, .invalidURL)
                    continue
                }
                admitted.append((index, url, origin))
            }
        }

        if !admitted.isEmpty {
            await withTaskGroup(of: (Int, RichPresentationFetchedImage)?.self) { group in
                for item in admitted {
                    let slot = slots[item.index]
                    group.addTask {
                        await (item.index, self.fetchOne(slot: slot, url: item.url, origin: item.origin, deadline: deadline, budget: budget))
                    }
                }
                // Deadline sentinel: also returns when the publication is cancelled.
                group.addTask {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    return nil
                }
                var remaining = admitted.count
                while remaining > 0, let next = await group.next() {
                    guard let finished = next else { break }
                    results[finished.0] = finished.1
                    remaining -= 1
                }
                // Unfinished downloads and decode waits stop now; an executing decode keeps its permit.
                group.cancelAll()
            }
        }
        try Task.checkCancellation()
        return results.enumerated().map { index, result in
            result ?? Self.failed(slots[index], .deadline)
        }
    }

    // MARK: - One image

    private func fetchOne(
        slot: RichPresentationImageSlot,
        url: URL,
        origin: String,
        deadline: ContinuousClock.Instant,
        budget: RichPresentationByteBudget
    ) async -> RichPresentationFetchedImage {
        do {
            try await downloadPermits.acquire()
        } catch {
            return Self.failed(slot, .deadline)
        }
        // The permit now belongs to the transfer: it returns when URLSession reports the task's
        // terminal callback, not when this caller stops waiting, so cancelled or rejected
        // transfers that are still stopping keep counting against the app-wide bound.
        let permits = downloadPermits
        let body = await download(url: url, deadline: deadline, budget: budget) { permits.release() }

        switch body {
        case let .failure(code):
            return Self.failed(slot, code)
        case let .success(response):
            let normalized: Result<RichPresentationNormalizedImage, RichPresentationImageFailureCode>
            do {
                normalized = try await decodeOffMain(response.data, mimeType: response.mimeType)
            } catch {
                return Self.failed(slot, .deadline)
            }
            switch normalized {
            case let .failure(code):
                return Self.failed(slot, code)
            case let .success(image):
                let asset = RichPresentationImageAsset(
                    assetID: UUID(),
                    width: image.width,
                    height: image.height,
                    alt: slot.request.alt,
                    credit: slot.request.credit,
                    origin: origin
                )
                return RichPresentationFetchedImage(
                    outcome: RichPresentationArticleImageOutcome(
                        sectionIndex: slot.sectionIndex,
                        articleIndex: slot.articleIndex,
                        outcome: .asset(asset)
                    ),
                    jpegData: image.jpegData
                )
            }
        }
    }

    private func download(
        url: URL,
        deadline: ContinuousClock.Instant,
        budget: RichPresentationByteBudget,
        releasePermit: @escaping @Sendable () -> Void
    ) async -> Result<RichPresentationImageDownload.Body, RichPresentationImageFailureCode> {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero, !Task.isCancelled else {
            // No task was created, so no transfer holds the permit.
            releasePermit()
            return .failure(.deadline)
        }
        let components = remaining.components
        let seconds = TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18

        // The URL is the validated request URL exactly as supplied, including any signed query.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: seconds)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("image/jpeg, image/png", forHTTPHeaderField: "Accept")

        let task = session.dataTask(with: request)
        let download = RichPresentationImageDownload(
            task: task,
            maxImageBytes: limits.maxImageBytes,
            budget: budget,
            releaseTransport: releasePermit
        )
        task.delegate = download
        return await download.run(task)
    }

    /// Runs the native decode off-main under the decode permit. The permit is released only when
    /// the decode itself ends; a caller cancelled meanwhile stops waiting and the result is dropped.
    private func decodeOffMain(
        _ data: Data,
        mimeType: String?
    ) async throws -> Result<RichPresentationNormalizedImage, RichPresentationImageFailureCode> {
        try await decodePermits.acquire()
        let permits = decodePermits
        let decode = decode
        let limits = limits
        let waiter = RichPresentationOneShot<Result<RichPresentationNormalizedImage, RichPresentationImageFailureCode>>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard waiter.install(continuation) else {
                    // Cancelled before the decode started: nothing native is running.
                    permits.release()
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = decode(data, mimeType, limits)
                    permits.release()
                    waiter.resume(returning: result)
                }
            }
        } onCancel: {
            waiter.cancel()
        }
    }

    private static func failed(_ slot: RichPresentationImageSlot, _ code: RichPresentationImageFailureCode) -> RichPresentationFetchedImage {
        RichPresentationFetchedImage(
            outcome: RichPresentationArticleImageOutcome(
                sectionIndex: slot.sectionIndex,
                articleIndex: slot.articleIndex,
                outcome: .failed(code)
            ),
            jpegData: nil
        )
    }
}

// MARK: - Request policy

/// Session- and task-level policy: refuse every redirect, keep normal server-trust evaluation, and
/// cancel every other authentication challenge (no credentials are ever offered).
class RichPresentationImageRequestPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RichPresentationImageRequestPolicy()

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        noteRedirectRefused()
        completionHandler(nil)
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(Self.disposition(for: challenge.protectionSpace.authenticationMethod), nil)
    }

    static func disposition(for authenticationMethod: String) -> URLSession.AuthChallengeDisposition {
        authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge
    }

    func noteRedirectRefused() {}
}

/// Per-request delegate: streams the body under the per-image and per-artifact byte bounds and
/// resolves exactly one terminal result. The waiter may be resumed early (cancellation, rejection),
/// but the transport permit is released exactly once, from URLSession's terminal callback (or at
/// once when the task never started), so it tracks the actual task lifetime.
final class RichPresentationImageDownload: RichPresentationImageRequestPolicy, URLSessionDataDelegate, @unchecked Sendable {
    struct Body {
        let data: Data
        let mimeType: String?
    }

    /// Weak (the task retains this delegate) and used only to cancel; `run(_:)` holds the task
    /// strongly until it resumes, after which the session retains it until completion.
    private weak var task: URLSessionDataTask?
    private let maxImageBytes: Int
    private let budget: RichPresentationByteBudget
    private let releaseTransport: @Sendable () -> Void
    private let lock = NSLock()
    private var transportReleased = false
    private var continuation: CheckedContinuation<Result<Body, RichPresentationImageFailureCode>, Never>?
    private var terminal: Result<Body, RichPresentationImageFailureCode>?
    private var delivered = false
    private var redirectRefused = false
    private var mimeType: String?
    private var data = Data()

    init(
        task: URLSessionDataTask,
        maxImageBytes: Int,
        budget: RichPresentationByteBudget,
        releaseTransport: @escaping @Sendable () -> Void
    ) {
        self.task = task
        self.maxImageBytes = maxImageBytes
        self.budget = budget
        self.releaseTransport = releaseTransport
    }

    func run(_ task: URLSessionDataTask) async -> Result<Body, RichPresentationImageFailureCode> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let terminal {
                    // Cancelled before the transfer started: no transport work exists.
                    delivered = true
                    lock.unlock()
                    continuation.resume(returning: terminal)
                    releaseTransportOnce()
                    return
                }
                self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            finish(.failure(.deadline))
        }
    }

    override func noteRedirectRefused() {
        lock.lock()
        redirectRefused = true
        lock.unlock()
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(.fetchFailed))
            return
        }
        lock.lock()
        let refused = redirectRefused
        lock.unlock()
        if refused || (300 ..< 400).contains(http.statusCode) {
            completionHandler(.cancel)
            finish(.failure(.redirectRejected))
        } else if http.statusCode != 200 {
            completionHandler(.cancel)
            finish(.failure(.fetchFailed))
        } else if http.expectedContentLength > Int64(maxImageBytes) {
            completionHandler(.cancel)
            finish(.failure(.tooLarge))
        } else {
            lock.lock()
            // The declared header, not `mimeType`: URLSession content-sniffing can replace that.
            mimeType = http.value(forHTTPHeaderField: "Content-Type")
            lock.unlock()
            completionHandler(.allow)
        }
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard terminal == nil else {
            lock.unlock()
            return
        }
        // Decoded bytes: the bound applies after any Content-Encoding decompression.
        let withinImage = data.count + chunk.count <= maxImageBytes
        let withinArtifact = withinImage && budget.charge(chunk.count)
        if withinArtifact {
            data.append(chunk)
        }
        lock.unlock()
        if !withinArtifact {
            finish(.failure(.tooLarge))
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        // The task's actual end: only now may a replacement transfer take its permit.
        releaseTransportOnce()
        lock.lock()
        let refused = redirectRefused
        let body = Body(data: data, mimeType: mimeType)
        lock.unlock()
        if refused {
            finish(.failure(.redirectRejected))
        } else if let error {
            finish(.failure((error as? URLError)?.code == .timedOut ? .deadline : .fetchFailed))
        } else {
            finish(.success(body))
        }
    }

    private func releaseTransportOnce() {
        lock.lock()
        let first = !transportReleased
        transportReleased = true
        lock.unlock()
        if first {
            releaseTransport()
        }
    }

    /// Records the first terminal result, cancels the transfer when it ends early, refunds the
    /// artifact budget on failure and resumes the waiter once.
    private func finish(_ result: Result<Body, RichPresentationImageFailureCode>) {
        lock.lock()
        if terminal == nil {
            terminal = result
            if case .failure = result {
                budget.refund(data.count)
                data = Data()
            }
        }
        let final = terminal
        let waiter = delivered ? nil : continuation
        if waiter != nil {
            delivered = true
            continuation = nil
        }
        lock.unlock()
        if case .failure = final {
            task?.cancel()
        }
        if let waiter, let final {
            waiter.resume(returning: final)
        }
    }
}

// MARK: - Concurrency primitives

/// FIFO permits whose waits are cancellable; a cancelled waiter takes no permit.
final class RichPresentationPermitPool: @unchecked Sendable {
    private let lock = NSLock()
    private var available: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(permits: Int) {
        precondition(permits > 0)
        available = permits
    }

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if available > 0 {
                    available -= 1
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.firstIndex { $0.id == id }.map { waiters.remove(at: $0) }
            lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            available += 1
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.continuation.resume()
        }
    }
}

/// Streamed bytes retained by one artifact's downloads; failed downloads refund theirs.
final class RichPresentationByteBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var used = 0

    init(limit: Int) {
        self.limit = limit
    }

    func charge(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard used + count <= limit else { return false }
        used += count
        return true
    }

    func refund(_ count: Int) {
        lock.lock()
        used = max(0, used - count)
        lock.unlock()
    }
}

/// A continuation resumed at most once; resuming after cancellation discards the value.
final class RichPresentationOneShot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var done = false

    /// Returns `false` (after resuming with `CancellationError`) when cancellation came first.
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if done {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    func cancel() {
        take()?.resume(throwing: CancellationError())
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return nil }
        done = true
        let taken = continuation
        continuation = nil
        return taken
    }
}
