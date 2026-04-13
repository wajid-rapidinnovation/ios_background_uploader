import Flutter
import UIKit

public class IosBackgroundUploaderPlugin: NSObject, FlutterPlugin, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {

    // MARK: - Properties
    private var backgroundSession: URLSession!
    private static var eventSink: FlutterEventSink?
    private var responseDataMap = [Int: Data]() // Store data per task
    private var activeTasks = 0 // Track number of in-flight tasks

    // Static property to store the background session completion handler
    public static var backgroundSessionCompletionHandler: (() -> Void)?

    // MARK: - Plugin Registration
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "ios_background_uploader", binaryMessenger: registrar.messenger())
        let eventChannel = FlutterEventChannel(name: "ios_background_uploader/events", binaryMessenger: registrar.messenger())

        let instance = IosBackgroundUploaderPlugin()
        eventChannel.setStreamHandler(instance)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // MARK: - Init
    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.desireweb.iosuploader.customUploader")
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        // Limit parallel connections per host to avoid overwhelming the server
        config.httpMaximumConnectionsPerHost = 6
        config.sessionSendsLaunchEvents = true
        // Wait for connectivity instead of failing immediately on transient network loss
        if #available(iOS 11.0, *) {
            config.waitsForConnectivity = true
        }
        // Keep network connection alive longer when entering background
        config.shouldUseExtendedBackgroundIdleMode = true
        // Timeout for each request attempt (5 minutes — allows large files on slow networks)
        config.timeoutIntervalForRequest = 300
        // Total time allowed for the upload resource (1 hour — prevents indefinite hanging)
        config.timeoutIntervalForResource = 3600

        // Dedicated delegate queue with elevated QoS for faster callback processing
        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.desireweb.iosuploader.delegateQueue"
        delegateQueue.qualityOfService = .userInitiated
        delegateQueue.maxConcurrentOperationCount = 1

        backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    // MARK: - Method Call Handling
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "uploadFiles":
            if let args = call.arguments as? [String: Any] {
                startUpload(args: args)
                result("upload_started")
            } else {
                result("invalid_arguments")
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Upload Logic
    private func startUpload(args: [String: Any]) {
        guard let urlString = args["url"] as? String,
              let url = URL(string: urlString),
              let files = args["files"] as? [String] else {
            print("Invalid arguments for upload")
            return
        }

        let method = args["method"] as? String ?? "POST"
        let headers = args["headers"] as? [String: String] ?? [:]
        let fields = args["fields"] as? [String: String] ?? [:]
        let tag = args["tag"] as? String ?? UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if files.count > 1 || !fields.isEmpty {
            // Multipart form-data upload
            let boundary = "Boundary-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let body = createMultipartBody(files: files, fields: fields, boundary: boundary)
            let tempDir = FileManager.default.temporaryDirectory
            let bodyFileURL = tempDir.appendingPathComponent("upload-\(tag).tmp")
            do {
                try body.write(to: bodyFileURL)
            } catch {
                print("Error writing body: \(error)")
                return
            }
            activeTasks += 1
            let uploadTask = backgroundSession.uploadTask(with: request, fromFile: bodyFileURL)
            uploadTask.taskDescription = tag
            // High priority so iOS doesn't deprioritize our uploads in background
            uploadTask.priority = URLSessionTask.highPriority
            uploadTask.resume()
        } else if let filePath = files.first {
            // Single file upload
            let fileURL = URL(fileURLWithPath: filePath)
            activeTasks += 1
            let uploadTask = backgroundSession.uploadTask(with: request, fromFile: fileURL)
            uploadTask.taskDescription = tag
            uploadTask.priority = URLSessionTask.highPriority
            uploadTask.resume()
        }
    }

    private func createMultipartBody(files: [String], fields: [String: String], boundary: String) -> Data {
        var body = Data()
        for (key, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        for filePath in files {
            let url = URL(fileURLWithPath: filePath)
            let filename = url.lastPathComponent
            let mimetype = "image/jpeg" // TODO: detect MIME dynamically if needed

            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mimetype)\r\n\r\n".data(using: .utf8)!)
            if let fileData = try? Data(contentsOf: url) {
                body.append(fileData)
            }
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    // MARK: - URLSession Delegates
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let taskId = dataTask.taskIdentifier
        if responseDataMap[taskId] == nil {
            responseDataMap[taskId] = Data()
        }
        responseDataMap[taskId]?.append(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                           totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend) * 100.0
        DispatchQueue.main.async {
            IosBackgroundUploaderPlugin.eventSink?([
                "status": "progress",
                "progress": progress,
                "tag": task.taskDescription ?? ""
            ])
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier
        let responseBody = responseDataMap[taskId].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        responseDataMap.removeValue(forKey: taskId)
        activeTasks = max(0, activeTasks - 1)

        DispatchQueue.main.async {
            if let error = error {
                IosBackgroundUploaderPlugin.eventSink?([
                    "status": "failed",
                    "error": error.localizedDescription,
                    "tag": task.taskDescription ?? ""
                ])
            } else if let httpResponse = task.response as? HTTPURLResponse {
                IosBackgroundUploaderPlugin.eventSink?([
                    "status": "completed",
                    "code": httpResponse.statusCode,
                    "response": responseBody,
                    "tag": task.taskDescription ?? ""
                ])
            } else {
                IosBackgroundUploaderPlugin.eventSink?([
                    "status": "completed",
                    "response": responseBody,
                    "tag": task.taskDescription ?? ""
                ])
            }
        }
    }

    // MARK: - Background Session Lifecycle
    // Called when ALL background tasks for this session have completed.
    // This is the correct place to call the completion handler — not per-task.
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            if let handler = IosBackgroundUploaderPlugin.backgroundSessionCompletionHandler {
                handler()
                IosBackgroundUploaderPlugin.backgroundSessionCompletionHandler = nil
            }
        }
    }

    // Called when the session becomes invalid (e.g. due to error or explicit invalidation)
    public func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if let error = error {
            print("[IosBackgroundUploader] Session invalidated with error: \(error.localizedDescription)")
        }
        DispatchQueue.main.async {
            if let handler = IosBackgroundUploaderPlugin.backgroundSessionCompletionHandler {
                handler()
                IosBackgroundUploaderPlugin.backgroundSessionCompletionHandler = nil
            }
        }
    }

    // Called when waitsForConnectivity is enabled and the session is waiting
    @available(iOS 11.0, *)
    public func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        DispatchQueue.main.async {
            IosBackgroundUploaderPlugin.eventSink?([
                "status": "waiting_for_connectivity",
                "tag": task.taskDescription ?? ""
            ])
        }
    }
}

// MARK: - Flutter Stream Handler
extension IosBackgroundUploaderPlugin: FlutterStreamHandler {
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        IosBackgroundUploaderPlugin.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        IosBackgroundUploaderPlugin.eventSink = nil
        return nil
    }
}