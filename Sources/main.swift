import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import WebKit

private let sourcePollInterval: TimeInterval = 0.05
private let sourceSettleDelay: TimeInterval = 0.12

struct AppConfiguration {
    let inputURL: URL?
    let reverseCommandTemplate: String?
    let backend: RenderBackend
    let showFigures: Bool
    let reverseLookupTarget: ReverseLookupTarget
}

enum RenderBackend {
    case xdvSVG
    case pdfNative
}

enum ReverseLookupTarget: String, CaseIterable {
    case cursor
    case code

    var title: String {
        switch self {
        case .cursor: return "Cursor"
        case .code: return "Code"
        }
    }

    var commandTemplate: String {
        switch self {
        case .cursor: return "cursor -g {input}:{line}:{column}"
        case .code: return "code -g {input}:{line}:{column}"
        }
    }
}

enum InputKind {
    case tex
    case xdv

    static func detect(path: URL) throws -> InputKind {
        switch path.pathExtension.lowercased() {
        case "tex": return .tex
        case "xdv": return .xdv
        default:
            throw ViewerError.unsupportedInput(path.path)
        }
    }
}

enum ViewerError: Error, LocalizedError {
    case unsupportedInput(String)
    case missingTool(String)
    case missingSource(String)
    case processFailed(String)
    case missingOutput(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedInput(path):
            return "Input must be a .tex or .xdv file: \(path)"
        case let .missingTool(name):
            return "Missing required tool: \(name)"
        case let .missingSource(path):
            return "Missing source file: \(path)"
        case let .processFailed(message):
            return message
        case let .missingOutput(path):
            return "Expected output was not created: \(path)"
        }
    }
}

struct RenderResult {
    let backend: RenderBackend
    let displayName: String
    let xdvURL: URL?
    let pdfURL: URL?
    let syncTeXURL: URL?
    let pages: [PageAsset]
    let totalPages: Int
    let renderedMTime: Date
}

struct PageAsset {
    let pageNumber: Int
    let url: URL
    let viewBox: SVGViewBox
}

struct SVGViewBox {
    let minX: Double
    let minY: Double
    let width: Double
    let height: Double
}

final class RenderPipeline {
    private let toolSearchPaths = [
        "/Library/TeX/texbin",
        "/usr/texbin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ]

    let inputURL: URL
    let inputKind: InputKind
    let backend: RenderBackend
    let showFigures: Bool
    let outputRoot: URL
    let latexBuildRoot: URL?
    private var cachedTotalPages: Int?

    init(inputURL: URL, backend: RenderBackend, showFigures: Bool) throws {
        self.inputURL = inputURL.resolvingSymlinksInPath()
        self.inputKind = try InputKind.detect(path: inputURL)
        self.backend = backend
        self.showFigures = showFigures
        self.outputRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("xdv-native-viewer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        if self.inputKind == .tex {
            let buildRoot = self.inputURL.deletingLastPathComponent()
                .appendingPathComponent(".xdv-viewer-build", isDirectory: true)
            self.latexBuildRoot = buildRoot
            try FileManager.default.createDirectory(at: buildRoot, withIntermediateDirectories: true)
        } else {
            self.latexBuildRoot = nil
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: outputRoot)
    }

    func render(requestedPages: [Int]? = nil) throws -> RenderResult {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ViewerError.missingSource(inputURL.path)
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: inputURL.path)
        let modified = attrs[.modificationDate] as? Date ?? Date()

        switch backend {
        case .xdvSVG:
            let xdvURL = try compileXDVIfNeeded()
            let pages = try renderSVGPages(from: xdvURL, requestedPages: requestedPages)
            let totalPages = requestedPages == nil ? pages.count : max(cachedTotalPages ?? 0, pages.map(\.pageNumber).max() ?? 0)
            if requestedPages == nil {
                cachedTotalPages = totalPages
            }
            let displayName = inputKind == .tex
                ? "\(inputURL.lastPathComponent) -> \(xdvURL.lastPathComponent)"
                : inputURL.lastPathComponent
            let syncTeXURL = xdvURL.deletingPathExtension().appendingPathExtension("synctex.gz")
            return RenderResult(
                backend: backend,
                displayName: displayName,
                xdvURL: xdvURL,
                pdfURL: nil,
                syncTeXURL: FileManager.default.fileExists(atPath: syncTeXURL.path) ? syncTeXURL : nil,
                pages: pages,
                totalPages: totalPages,
                renderedMTime: modified
            )
        case .pdfNative:
            let pdfResult = try compilePDFIfNeeded()
            let displayName = inputKind == .tex
                ? "\(inputURL.lastPathComponent) -> \(pdfResult.pdfURL.lastPathComponent)"
                : "\(inputURL.lastPathComponent) -> \(pdfResult.pdfURL.lastPathComponent)"
            return RenderResult(
                backend: backend,
                displayName: displayName,
                xdvURL: pdfResult.xdvURL,
                pdfURL: pdfResult.pdfURL,
                syncTeXURL: pdfResult.syncTeXURL,
                pages: [],
                totalPages: pdfResult.totalPages,
                renderedMTime: modified
            )
        }
    }

    private func compileXDVIfNeeded() throws -> URL {
        switch inputKind {
        case .xdv:
            return inputURL
        case .tex:
            guard which("latexmk") != nil else {
                throw ViewerError.missingTool("latexmk")
            }

            let compileSourceURL = try compileSourceURL()
            let xdvURL = try latexOutputURL(extension: "xdv")
            let syncTeXURL = try latexOutputURL(extension: "synctex.gz")
            let previousModified = modificationDate(for: xdvURL)
            let output = try runProcess(
                executable: "latexmk",
                arguments: latexmkArguments(noPDF: true, compileSourceURL: compileSourceURL),
                directory: inputURL.deletingLastPathComponent()
            )

            if output.exitCode != 0 {
                let combined = output.stdout + output.stderr
                if FileManager.default.fileExists(atPath: xdvURL.path),
                   combined.contains("xdvipdfmx: failed to create output file") {
                    return xdvURL
                }
                let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? output.stdout
                    : output.stderr
                throw ViewerError.processFailed("latexmk failed:\n\(message.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            guard FileManager.default.fileExists(atPath: xdvURL.path) else {
                throw ViewerError.missingOutput(xdvURL.path)
            }

            if !FileManager.default.fileExists(atPath: syncTeXURL.path) {
                _ = try runProcess(
                    executable: "xelatex",
                    arguments: xelatexDirectArguments(noPDF: true),
                    directory: inputURL.deletingLastPathComponent()
                )
            }

            if let previousModified, let currentModified = modificationDate(for: xdvURL), currentModified < previousModified {
                throw ViewerError.processFailed("latexmk did not refresh \(xdvURL.lastPathComponent)")
            }

            return xdvURL
        }
    }

    private func compilePDFIfNeeded() throws -> (pdfURL: URL, xdvURL: URL?, syncTeXURL: URL?, totalPages: Int) {
        switch inputKind {
        case .tex:
            guard which("latexmk") != nil else {
                throw ViewerError.missingTool("latexmk")
            }

            let compileSourceURL = try compileSourceURL()
            let pdfURL = try latexOutputURL(extension: "pdf")
            let syncTeXURL = try latexOutputURL(extension: "synctex.gz")
            let output = try runProcess(
                executable: "latexmk",
                arguments: latexmkArguments(noPDF: false, compileSourceURL: compileSourceURL),
                directory: inputURL.deletingLastPathComponent()
            )

            guard output.exitCode == 0 else {
                let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? output.stdout
                    : output.stderr
                throw ViewerError.processFailed("latexmk failed:\n\(message.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            guard FileManager.default.fileExists(atPath: pdfURL.path) else {
                throw ViewerError.missingOutput(pdfURL.path)
            }

            let pageCount = try pdfPageCount(at: pdfURL)
            return (pdfURL, nil, FileManager.default.fileExists(atPath: syncTeXURL.path) ? syncTeXURL : nil, pageCount)
        case .xdv:
            guard which("xdvipdfmx") != nil else {
                throw ViewerError.missingTool("xdvipdfmx")
            }

            let pdfURL = outputRoot.appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent + ".pdf")
            let output = try runProcess(
                executable: "xdvipdfmx",
                arguments: ["-o", pdfURL.path, inputURL.path],
                directory: inputURL.deletingLastPathComponent()
            )

            guard output.exitCode == 0 else {
                let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? output.stdout
                    : output.stderr
                throw ViewerError.processFailed("xdvipdfmx failed:\n\(message.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            guard FileManager.default.fileExists(atPath: pdfURL.path) else {
                throw ViewerError.missingOutput(pdfURL.path)
            }

            let syncTeXURL = inputURL.deletingPathExtension().appendingPathExtension("synctex.gz")
            let pageCount = try pdfPageCount(at: pdfURL)
            return (pdfURL, inputURL, FileManager.default.fileExists(atPath: syncTeXURL.path) ? syncTeXURL : nil, pageCount)
        }
    }

    private func latexmkArguments(noPDF: Bool, compileSourceURL: URL) -> [String] {
        var arguments = [
                    "-g",
                    "-xelatex"
        ]
        if let latexBuildRoot {
            arguments.append("-outdir=\(latexBuildRoot.path)")
        }
        if !showFigures {
            arguments.append("-jobname=\(inputURL.deletingPathExtension().lastPathComponent)")
        }
        arguments.append("-e")
        let command = noPDF
            ? "$xelatex=q/\(xelatexLatexmkCommand(noPDF: true)) %O %S/; $xdvipdfmx=q/true/;"
            : "$xelatex=q/\(xelatexLatexmkCommand(noPDF: false)) %O %S/;"
        arguments.append(command)
        arguments.append(compileSourceURL.path)
        return arguments
    }

    private func renderSVGPages(from xdvURL: URL, requestedPages: [Int]? = nil) throws -> [PageAsset] {
        guard which("dvisvgm") != nil else {
            throw ViewerError.missingTool("dvisvgm")
        }

        let safeStem = xdvURL.deletingPathExtension().lastPathComponent
            .map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        let renderDir = outputRoot.appendingPathComponent("\(safeStem)-\(Int(Date().timeIntervalSince1970 * 1000))", isDirectory: true)
        try FileManager.default.createDirectory(at: renderDir, withIntermediateDirectories: true)

        let pageSpec: String
        if let requestedPages, !requestedPages.isEmpty {
            pageSpec = makePageSpec(from: requestedPages)
        } else {
            pageSpec = "1-"
        }

        let output = try runProcess(
            executable: "dvisvgm",
            arguments: [
                "--page=\(pageSpec)",
                "--no-fonts",
                "--output=page-%p.svg",
                xdvURL.path,
            ],
            directory: renderDir
        )

        guard output.exitCode == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? output.stdout
                : output.stderr
            throw ViewerError.processFailed("dvisvgm failed:\n\(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let pageURLs = try FileManager.default.contentsOfDirectory(at: renderDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("page-") && $0.pathExtension == "svg" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !pageURLs.isEmpty else {
            throw ViewerError.missingOutput("No SVG pages were generated.")
        }

        let pages = try pageURLs.map { url in
            let stem = url.deletingPathExtension().lastPathComponent
            guard let suffix = stem.split(separator: "-").last,
                  let pageNumber = Int(suffix)
            else {
                throw ViewerError.processFailed("Could not parse page number from \(url.lastPathComponent)")
            }
            return PageAsset(pageNumber: pageNumber, url: url, viewBox: try parseViewBox(from: url))
        }

        return pages
    }

    private func makePageSpec(from pages: [Int]) -> String {
        let uniquePages = Array(Set(pages.filter { $0 >= 1 })).sorted()
        guard let first = uniquePages.first else { return "1" }

        var ranges: [String] = []
        var rangeStart = first
        var previous = first

        for page in uniquePages.dropFirst() {
            if page == previous + 1 {
                previous = page
                continue
            }
            ranges.append(rangeStart == previous ? "\(rangeStart)" : "\(rangeStart)-\(previous)")
            rangeStart = page
            previous = page
        }

        ranges.append(rangeStart == previous ? "\(rangeStart)" : "\(rangeStart)-\(previous)")
        return ranges.joined(separator: ",")
    }

    private func parseViewBox(from svgURL: URL) throws -> SVGViewBox {
        let svg = try String(contentsOf: svgURL, encoding: .utf8)
        let pattern = #"viewBox=['"]([^'"]+)['"]"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsrange = NSRange(svg.startIndex..<svg.endIndex, in: svg)
        guard let match = regex.firstMatch(in: svg, range: nsrange),
              let range = Range(match.range(at: 1), in: svg)
        else {
            throw ViewerError.processFailed("Could not parse SVG viewBox for \(svgURL.lastPathComponent)")
        }
        let values = svg[range].split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard values.count == 4 else {
            throw ViewerError.processFailed("Invalid SVG viewBox for \(svgURL.lastPathComponent)")
        }
        return SVGViewBox(minX: values[0], minY: values[1], width: values[2], height: values[3])
    }

    private func pdfPageCount(at url: URL) throws -> Int {
        guard let document = PDFDocument(url: url) else {
            throw ViewerError.processFailed("Could not open generated PDF at \(url.path)")
        }
        return document.pageCount
    }

    private func xelatexLatexmkCommand(noPDF: Bool) -> String {
        (["xelatex"] + xelatexBaseArguments(noPDF: noPDF)).joined(separator: " ")
    }

    private func xelatexBaseArguments(noPDF: Bool) -> [String] {
        var args = ["-synctex=1", "-interaction=nonstopmode", "-halt-on-error", "-file-line-error"]
        if noPDF {
            args.insert("-no-pdf", at: 0)
        }
        return args
    }

    private func xelatexDirectArguments(noPDF: Bool) -> [String] {
        var args = xelatexBaseArguments(noPDF: noPDF)
        if let latexBuildRoot {
            args.append("-output-directory=\(latexBuildRoot.path)")
        }
        if !showFigures {
            args.append("-jobname=\(inputURL.deletingPathExtension().lastPathComponent)")
        }
        args.append(compileSourceFileName())
        return args
    }

    private func compileSourceURL() throws -> URL {
        guard inputKind == .tex, !showFigures else { return inputURL }
        guard let latexBuildRoot else { return inputURL }
        let wrapperURL = latexBuildRoot
            .appendingPathComponent("draft-\(inputURL.deletingPathExtension().lastPathComponent).tex")
        let wrapper = """
        \\PassOptionsToPackage{draft}{graphicx}
        \\makeatletter
        \\AtBeginDocument{\\Gin@drafttrue}
        \\makeatother
        \\input{"\(inputURL.path)"}
        """
        try wrapper.write(to: wrapperURL, atomically: true, encoding: .utf8)
        return wrapperURL
    }

    private func compileSourceFileName() -> String {
        if showFigures {
            return inputURL.path
        }
        return latexBuildRoot?
            .appendingPathComponent("draft-\(inputURL.deletingPathExtension().lastPathComponent).tex")
            .path ?? inputURL.path
    }

    private func latexOutputURL(extension pathExtension: String) throws -> URL {
        guard let latexBuildRoot else {
            throw ViewerError.processFailed("LaTeX build directory is not available.")
        }
        return latexBuildRoot
            .appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(pathExtension)
    }

    func which(_ executable: String) -> String? {
        for directory in toolSearchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executable).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [executable]
        process.environment = processEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }

    private func modificationDate(for url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    func runProcess(executable: String, arguments: [String], directory: URL) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.currentDirectoryURL = directory
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.environment = processEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, stdout, stderr)
    }

    private func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let path = toolSearchPaths.joined(separator: ":")
        if let existing = environment["PATH"], !existing.isEmpty {
            environment["PATH"] = path + ":" + existing
        } else {
            environment["PATH"] = path
        }
        return environment
    }
}

final class ViewerWebView: WKWebView {
    var magnifyHandler: ((CGFloat) -> Void)?

    override func magnify(with event: NSEvent) {
        magnifyHandler?(event.magnification)
    }
}

final class SyncPDFView: PDFView {
    var clickHandler: ((Int, CGPoint) -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let viewPoint = convert(event.locationInWindow, from: nil)
            if let page = page(for: viewPoint, nearest: true),
               let document = document {
                let pagePoint = convert(viewPoint, to: page)
                let pageBounds = page.bounds(for: displayBox)
                let syncTeXPoint = CGPoint(
                    x: min(max(pagePoint.x - pageBounds.minX, 0), pageBounds.width),
                    y: min(max(pageBounds.maxY - pagePoint.y, 0), pageBounds.height)
                )
                let pageIndex = document.index(for: page)
                clickHandler?(pageIndex, syncTeXPoint)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

final class ViewerWindowController: NSWindowController, NSTextFieldDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private var pipeline: RenderPipeline?
    private let customReverseCommandTemplate: String?
    private let renderQueue = DispatchQueue(label: "xdv-native-render", qos: .userInitiated)
    private var currentInputURL: URL?
    private var backend: RenderBackend
    private var showFigures: Bool
    private var reverseLookupTarget: ReverseLookupTarget

    private lazy var webView: ViewerWebView = {
        let controller = WKUserContentController()
        controller.add(self, name: "reverseLookup")
        controller.add(self, name: "pageChanged")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let view = ViewerWebView(frame: .zero, configuration: configuration)
        return view
    }()
    private lazy var pdfView: SyncPDFView = {
        let view = SyncPDFView()
        view.autoScales = true
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .white
        view.clickHandler = { [weak self] pageIndex, point in
            self?.performReverseLookup(pageNumber: pageIndex + 1, xNorm: point.x, yNorm: point.y)
        }
        view.keyHandler = { [weak self] event in
            self?.handleKeyEvent(event) ?? false
        }
        return view
    }()
    private let statusLabel = NSTextField(labelWithString: "Starting viewer...")
    private let pageField = NSTextField(string: "1")
    private let pageTotalLabel = NSTextField(labelWithString: "/ 0")
    private let previousButton = NSButton(title: "Previous", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let zoomInButton = NSButton(title: "+", target: nil, action: nil)
    private let zoomOutButton = NSButton(title: "-", target: nil, action: nil)
    private let fitButton = NSButton(title: "Fit Width", target: nil, action: nil)
    private let singlePageButton = NSButton(title: "1 Page", target: nil, action: nil)
    private let doublePageButton = NSButton(title: "2 Pages", target: nil, action: nil)
    private let backendPopup = NSPopUpButton()
    private let figuresPopup = NSPopUpButton()
    private let reverseTargetPopup = NSPopUpButton()

    private var xdvURL: URL?
    private var pdfURL: URL?
    private var syncTeXURL: URL?
    private var pageAssetsByNumber: [Int: PageAsset] = [:]
    private var totalPages = 0
    private var currentPage = 0
    private var spread = 1
    private var zoom: Double = 1.0
    private var fitWidth = true
    private var lastRenderedMTime: Date?
    private var isRendering = false
    private var renderRequested = false
    private var pendingFullRender = false
    private var pendingMTime: Date?
    private var dirtySince: Date?
    private var pollTimer: DispatchSourceTimer?
    private var viewerShellReady = false
    private var loadingViewerShell = false
    private var pendingViewerStateScript: String?
    private var currentDisplayName = ""

    init(configuration: AppConfiguration) {
        self.customReverseCommandTemplate = configuration.reverseCommandTemplate
        self.backend = configuration.backend
        self.showFigures = configuration.showFigures
        self.reverseLookupTarget = configuration.reverseLookupTarget
        self.currentInputURL = configuration.inputURL

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1300, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LaTeX XDV Viewer"
        window.center()
        super.init(window: window)
        setupUI()
        if let inputURL = configuration.inputURL {
            openDocument(url: inputURL)
        } else {
            showEmptyState()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        pollTimer?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let container = NSStackView()
        container.orientation = .vertical
        container.translatesAutoresizingMaskIntoConstraints = false
        container.spacing = 0

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.distribution = .fill
        toolbar.spacing = 10
        toolbar.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        let navigationGroup = makeGroup([reloadButton, previousButton, nextButton])
        let zoomGroup = makeGroup([zoomOutButton, fitButton, zoomInButton])
        let spreadGroup = makeGroup([singlePageButton, doublePageButton])
        let pageGroup = makeGroup([pageField, pageTotalLabel])
        let backendGroup = makeLabeledGroup(title: "Mode", control: backendPopup)
        let figuresGroup = makeLabeledGroup(title: "Figures", control: figuresPopup)
        let reverseGroup = makeLabeledGroup(title: "SyncTeX", control: reverseTargetPopup)

        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pageField.alignment = .center
        pageField.delegate = self
        pageField.target = self
        pageField.action = #selector(pageFieldSubmitted(_:))
        pageField.translatesAutoresizingMaskIntoConstraints = false
        pageField.widthAnchor.constraint(equalToConstant: 58).isActive = true

        [reloadButton, previousButton, nextButton, zoomOutButton, zoomInButton, fitButton, singlePageButton, doublePageButton].forEach {
            $0.bezelStyle = .rounded
            $0.target = self
        }
        reloadButton.action = #selector(reloadRequested(_:))
        previousButton.action = #selector(previousPage(_:))
        nextButton.action = #selector(nextPage(_:))
        zoomOutButton.action = #selector(zoomOut(_:))
        zoomInButton.action = #selector(zoomIn(_:))
        fitButton.action = #selector(fitWidthMode(_:))
        singlePageButton.action = #selector(singlePageMode(_:))
        doublePageButton.action = #selector(doublePageMode(_:))

        configurePopups()

        toolbar.addArrangedSubview(navigationGroup)
        toolbar.addArrangedSubview(zoomGroup)
        toolbar.addArrangedSubview(spreadGroup)
        toolbar.addArrangedSubview(backendGroup)
        toolbar.addArrangedSubview(figuresGroup)
        toolbar.addArrangedSubview(reverseGroup)
        toolbar.addArrangedSubview(pageGroup)
        toolbar.addArrangedSubview(statusLabel)

        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.magnifyHandler = { [weak self] magnification in
            self?.handlePinchZoom(magnification: magnification)
        }
        webView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.isHidden = backend != .pdfNative

        container.addArrangedSubview(toolbar)
        container.addArrangedSubview(webView)
        container.addArrangedSubview(pdfView)
        contentView.addSubview(container)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            container.topAnchor.constraint(equalTo: contentView.topAnchor),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        updateControls()
        if backend == .xdvSVG {
            loadViewerShell()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pdfPageChanged(_:)),
            name: Notification.Name.PDFViewPageChanged,
            object: pdfView
        )
    }

    private func makeGroup(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func makeLabeledGroup(title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    private func configurePopups() {
        backendPopup.addItems(withTitles: ["SVG", "PDF"])
        backendPopup.selectItem(at: backend == .xdvSVG ? 0 : 1)
        backendPopup.target = self
        backendPopup.action = #selector(backendChanged(_:))

        figuresPopup.addItems(withTitles: ["Show", "Hide"])
        figuresPopup.selectItem(at: showFigures ? 0 : 1)
        figuresPopup.target = self
        figuresPopup.action = #selector(figuresChanged(_:))

        reverseTargetPopup.addItems(withTitles: ReverseLookupTarget.allCases.map(\.title))
        reverseTargetPopup.selectItem(withTitle: reverseLookupTarget.title)
        reverseTargetPopup.target = self
        reverseTargetPopup.action = #selector(reverseTargetChanged(_:))
    }

    private func showEmptyState() {
        statusLabel.stringValue = "Open a .tex or .xdv file to begin."
        totalPages = 0
        currentPage = 0
        currentDisplayName = ""
        xdvURL = nil
        pdfURL = nil
        syncTeXURL = nil
        pageAssetsByNumber.removeAll()
        pendingFullRender = true
        webView.isHidden = false
        pdfView.isHidden = true
        if !viewerShellReady && backend == .xdvSVG {
            loadViewerShell()
        }
        if viewerShellReady {
            updateViewerState(htmlPages: "", containerClass: "pages")
        } else {
            webView.loadHTMLString("<html><body style='background:#fff'></body></html>", baseURL: nil)
        }
        updateControls()
    }

    private func startPolling() {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + sourcePollInterval, repeating: sourcePollInterval)
        timer.setEventHandler { [weak self] in
            self?.pollForChanges()
        }
        timer.resume()
        pollTimer = timer
    }

    private func pollForChanges() {
        guard let pipeline,
              let modified = try? FileManager.default.attributesOfItem(atPath: pipeline.inputURL.path)[.modificationDate] as? Date else {
            return
        }

        let rendered = lastRenderedMTime
        let now = Date()

        if rendered == nil || modified > rendered! {
            if pendingMTime == nil || modified > pendingMTime! {
                pendingMTime = modified
                dirtySince = now
            }
        }

        guard let since = dirtySince else { return }
        guard now.timeIntervalSince(since) >= sourceSettleDelay else { return }

        pendingMTime = nil
        dirtySince = nil
        scheduleRender()
    }

    private func scheduleRender() {
        guard pipeline != nil else { return }
        if isRendering {
            renderRequested = true
            return
        }

        isRendering = true
        statusLabel.stringValue = "Rendering..."
        let shouldRenderAllPages = totalPages == 0 || pendingFullRender
        pendingFullRender = false
        let requestedPages = shouldRenderAllPages ? nil : requestedPageNumbers()
        renderQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let pipeline = self.pipeline else { return }
                let result = try pipeline.render(requestedPages: requestedPages)
                DispatchQueue.main.async {
                    self.apply(renderResult: result)
                }
            } catch {
                DispatchQueue.main.async {
                    self.show(error: error)
                }
            }
        }
    }

    func openDocument(url: URL) {
        do {
            let pipeline = try RenderPipeline(inputURL: url, backend: backend, showFigures: showFigures)
            self.pipeline = pipeline
            self.currentInputURL = url
            self.window?.title = "LaTeX XDV Viewer - \(url.lastPathComponent)"
            self.lastRenderedMTime = nil
            self.pendingMTime = nil
            self.dirtySince = nil
            self.pageAssetsByNumber.removeAll()
            self.totalPages = 0
            self.currentPage = 0
            self.pendingFullRender = true
            self.viewerShellReady = false
            self.loadingViewerShell = false
            self.pendingViewerStateScript = nil
            if backend == .xdvSVG {
                loadViewerShell()
            } else {
                webView.isHidden = true
                pdfView.isHidden = false
            }
            startPolling()
            scheduleRender()
        } catch {
            show(error: error)
        }
    }

    @objc func openDocumentPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "tex"), UTType(filenameExtension: "xdv")].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url {
            openDocument(url: url)
        }
    }

    @objc func closeDocumentWindow(_ sender: Any?) {
        window?.performClose(sender)
    }

    private func apply(renderResult: RenderResult) {
        isRendering = false
        lastRenderedMTime = renderResult.renderedMTime
        pdfURL = renderResult.pdfURL
        xdvURL = renderResult.xdvURL
        syncTeXURL = renderResult.syncTeXURL
        currentDisplayName = renderResult.displayName
        totalPages = renderResult.totalPages
        if renderResult.backend == .xdvSVG {
            renderResult.pages.forEach { pageAssetsByNumber[$0.pageNumber] = $0 }
        }
        currentPage = min(currentPage, max(totalPages - 1, 0))
        statusLabel.stringValue = "Rendered \(renderResult.backend == .pdfNative ? totalPages : renderResult.pages.count) page(s) from \(renderResult.displayName)"
        if renderResult.backend == .pdfNative {
            presentPDF(documentURL: renderResult.pdfURL, displayName: renderResult.displayName)
        } else {
            presentVisiblePages(displayName: renderResult.displayName)
        }
        if renderRequested {
            renderRequested = false
            scheduleRender()
        }
    }

    private func show(error: Error) {
        isRendering = false
        viewerShellReady = false
        loadingViewerShell = false
        pendingViewerStateScript = nil
        statusLabel.stringValue = error.localizedDescription
        pdfView.document = nil
        pdfView.isHidden = true
        webView.isHidden = false
        let html = """
        <html><body style="font-family: -apple-system; background: #fff; color: #922d1f; padding: 32px; white-space: pre-wrap;">\(escapeHTML(error.localizedDescription))</body></html>
        """
        webView.loadHTMLString(html, baseURL: pipeline?.outputRoot)
        if renderRequested {
            renderRequested = false
            scheduleRender()
        }
    }

    private func spreadStart(for index: Int) -> Int {
        spread == 2 ? (index / 2) * 2 : index
    }

    private func visiblePages() -> [PageAsset] {
        guard totalPages > 0 else { return [] }
        let start = spreadStart(for: currentPage)
        if spread == 2 {
            let numbers = [start + 1, start + 2].filter { $0 <= totalPages }
            return numbers.compactMap { pageAssetsByNumber[$0] }
        }
        return [pageAssetsByNumber[start + 1]].compactMap { $0 }
    }

    private func presentVisiblePages(displayName: String? = nil) {
        webView.isHidden = false
        pdfView.isHidden = true
        let pages = visiblePages()
        guard !pages.isEmpty else {
            updateViewerState(htmlPages: "", containerClass: "pages")
            updateControls()
            return
        }

        let widthPercent = fitWidth ? String(format: "%.2f", 100.0 / Double(max(pages.count, 1))) : nil
        let htmlPages = pages.map { page -> String in
            let src = page.url.absoluteString
            let style: String
            if fitWidth, let widthPercent {
                style = "width: calc(\(widthPercent)% - 12px); height: auto;"
            } else {
                style = "width: \(Int(800 * zoom))px; height: auto;"
            }
            return "<img class=\"page-base\" src=\"\(src)\" data-page=\"\(page.pageNumber)\" style=\"\(style)\" />"
        }.joined(separator: "")

        let start = spreadStart(for: currentPage)
        let pageInfo: String
        if spread == 2 && pages.count == 2 {
            pageInfo = "pages \(start + 1)-\(start + 2)"
        } else {
            pageInfo = "page \(start + 1)"
        }

        let name = displayName ?? currentInputURL?.lastPathComponent ?? "Untitled"
        statusLabel.stringValue = "\(name) | \(pageInfo)/\(totalPages) | \(Int(zoom * 100))%"
        updateViewerState(htmlPages: htmlPages, containerClass: "pages")
        updateControls()
    }

    private func presentPDF(documentURL: URL?, displayName: String? = nil) {
        guard let documentURL, let document = PDFDocument(url: documentURL) else {
            statusLabel.stringValue = "Could not open generated PDF."
            return
        }
        webView.isHidden = true
        pdfView.isHidden = false
        pdfView.document = document
        pdfView.displaysAsBook = false
        pdfView.displayMode = spread == 2 ? .twoUp : .singlePage
        pdfView.autoScales = fitWidth
        if !fitWidth {
            pdfView.scaleFactor = CGFloat(zoom)
        }
        let targetIndex = min(currentPage, max(document.pageCount - 1, 0))
        if let page = document.page(at: targetIndex) {
            pdfView.go(to: page)
        }
        zoom = Double(pdfView.scaleFactor)
        updateStatus(displayName: displayName)
        updateControls()
    }

    private func updateStatus(displayName: String? = nil) {
        let total = totalPages
        let start = spreadStart(for: currentPage)
        let pageInfo: String
        if spread == 2 && start + 1 < total {
            pageInfo = "pages \(start + 1)-\(start + 2)"
        } else {
            pageInfo = "page \(start + 1)"
        }

        let name = displayName ?? currentInputURL?.lastPathComponent ?? "Untitled"
        statusLabel.stringValue = "\(name) | \(pageInfo)/\(total) | \(Int(zoom * 100))%"
    }

    private func estimatedFitWidthZoom() -> Double {
        if backend == .pdfNative {
            return Double(pdfView.scaleFactor)
        }
        let pageCount = max(spread == 2 ? 2 : 1, 1)
        let horizontalPadding: Double = 48
        let interPageGap: Double = pageCount > 1 ? 24 * Double(pageCount - 1) : 0
        let availableWidth = max(Double(webView.bounds.width) - horizontalPadding - interPageGap, 200)
        let pageWidth = availableWidth / Double(pageCount)
        return min(max(pageWidth / 800.0, 0.25), 6.0)
    }

    private func handlePinchZoom(magnification: CGFloat) {
        guard backend == .xdvSVG else { return }
        let scaleDelta = max(0.5, min(1.75, 1.0 + Double(magnification)))
        if fitWidth {
            fitWidth = false
            zoom = estimatedFitWidthZoom()
        }
        zoom = min(max(zoom * scaleDelta, 0.25), 6.0)
        presentVisiblePages(displayName: currentDisplayName)
    }

    private func updateControls() {
        let total = totalPages
        pageField.stringValue = total > 0 ? "\(spreadStart(for: currentPage) + 1)" : "1"
        pageTotalLabel.stringValue = "/ \(total)"
        previousButton.isEnabled = total > 0 && spreadStart(for: currentPage) > 0
        nextButton.isEnabled = total > 0 && spreadStart(for: currentPage) + spread < total
        singlePageButton.state = spread == 1 ? .on : .off
        doublePageButton.state = spread == 2 ? .on : .off
    }

    @objc private func reloadRequested(_ sender: Any?) {
        pendingFullRender = true
        scheduleRender()
    }

    @objc private func previousPage(_ sender: Any?) {
        currentPage = max(0, spreadStart(for: currentPage) - spread)
        if backend == .pdfNative {
            if let page = pdfView.document?.page(at: currentPage) {
                pdfView.go(to: page)
            }
            updateStatus(displayName: currentDisplayName)
            updateControls()
        } else {
            showVisiblePagesOrRender()
        }
    }

    @objc private func nextPage(_ sender: Any?) {
        currentPage = min(max(totalPages - 1, 0), spreadStart(for: currentPage) + spread)
        if backend == .pdfNative {
            if let page = pdfView.document?.page(at: currentPage) {
                pdfView.go(to: page)
            }
            updateStatus(displayName: currentDisplayName)
            updateControls()
        } else {
            showVisiblePagesOrRender()
        }
    }

    @objc private func zoomIn(_ sender: Any?) {
        fitWidth = false
        if backend == .pdfNative {
            pdfView.autoScales = false
            pdfView.scaleFactor = min(pdfView.scaleFactor * 1.2, pdfView.maxScaleFactor)
            zoom = Double(pdfView.scaleFactor)
            updateStatus(displayName: currentDisplayName)
        } else {
            zoom = min(zoom * 1.2, 6.0)
            presentVisiblePages(displayName: currentDisplayName)
        }
    }

    @objc private func zoomOut(_ sender: Any?) {
        fitWidth = false
        if backend == .pdfNative {
            pdfView.autoScales = false
            pdfView.scaleFactor = max(pdfView.scaleFactor / 1.2, pdfView.minScaleFactor)
            zoom = Double(pdfView.scaleFactor)
            updateStatus(displayName: currentDisplayName)
        } else {
            zoom = max(zoom / 1.2, 0.25)
            presentVisiblePages(displayName: currentDisplayName)
        }
    }

    @objc private func fitWidthMode(_ sender: Any?) {
        fitWidth = true
        zoom = 1.0
        if backend == .pdfNative {
            pdfView.autoScales = true
            updateStatus(displayName: currentDisplayName)
        } else {
            presentVisiblePages(displayName: currentDisplayName)
        }
    }

    @objc private func singlePageMode(_ sender: Any?) {
        spread = 1
        currentPage = spreadStart(for: currentPage)
        if backend == .pdfNative {
            pdfView.displayMode = .singlePage
            presentPDF(documentURL: pdfURL, displayName: currentDisplayName)
        } else {
            showVisiblePagesOrRender()
        }
    }

    @objc private func doublePageMode(_ sender: Any?) {
        spread = 2
        currentPage = spreadStart(for: currentPage)
        if backend == .pdfNative {
            pdfView.displayMode = .twoUp
            presentPDF(documentURL: pdfURL, displayName: currentDisplayName)
        } else {
            showVisiblePagesOrRender()
        }
    }

    @objc private func pageFieldSubmitted(_ sender: Any?) {
        guard let value = Int(pageField.stringValue), value >= 1 else {
            updateControls()
            return
        }
        currentPage = min(max(value - 1, 0), max(totalPages - 1, 0))
        if spread == 2 {
            currentPage = spreadStart(for: currentPage)
        }
        if backend == .pdfNative {
            if let page = pdfView.document?.page(at: currentPage) {
                pdfView.go(to: page)
            }
            updateStatus(displayName: currentDisplayName)
            updateControls()
        } else {
            showVisiblePagesOrRender()
        }
    }

    @objc private func backendChanged(_ sender: Any?) {
        backend = backendPopup.indexOfSelectedItem == 0 ? .xdvSVG : .pdfNative
        if let currentInputURL {
            openDocument(url: currentInputURL)
        } else {
            showEmptyState()
        }
    }

    @objc private func figuresChanged(_ sender: Any?) {
        showFigures = figuresPopup.indexOfSelectedItem == 0
        if let currentInputURL {
            openDocument(url: currentInputURL)
        }
    }

    @objc private func reverseTargetChanged(_ sender: Any?) {
        let selectedIndex = max(0, reverseTargetPopup.indexOfSelectedItem)
        reverseLookupTarget = ReverseLookupTarget.allCases[selectedIndex]
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        pageFieldSubmitted(obj.object)
    }

    override func keyDown(with event: NSEvent) {
        if handleKeyEvent(event) {
            return
        }
        super.keyDown(with: event)
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 124:
            nextPage(nil)
            return true
        case 123:
            previousPage(nil)
            return true
        default:
            switch event.charactersIgnoringModifiers {
            case "+", "=":
                zoomIn(nil)
                return true
            case "-":
                zoomOut(nil)
                return true
            case "0":
                fitWidthMode(nil)
                return true
            case "1":
                singlePageMode(nil)
                return true
            case "2":
                doublePageMode(nil)
                return true
            case "r", "R":
                reloadRequested(nil)
                return true
            default:
                return false
            }
        }
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }

        if message.name == "reverseLookup",
           let page = body["page"] as? Int,
           let xNorm = body["xNorm"] as? Double,
           let yNorm = body["yNorm"] as? Double {
            performReverseLookup(pageNumber: page, xNorm: xNorm, yNorm: yNorm)
            return
        }

    }

    @objc private func pdfPageChanged(_ notification: Notification) {
        guard backend == .pdfNative,
              let page = pdfView.currentPage,
              let document = pdfView.document
        else { return }
        currentPage = document.index(for: page)
        updateStatus(displayName: currentDisplayName)
        updateControls()
    }

    private func performReverseLookup(pageNumber: Int, xNorm: Double, yNorm: Double) {
        if syncTeXURL == nil {
            DispatchQueue.main.async {
                self.statusLabel.stringValue = "No SyncTeX data available for this document. Rebuild from .tex or compile with -synctex=1."
            }
            return
        }

        let syncTargetURL: URL
        let x: Double
        let y: Double

        switch backend {
        case .xdvSVG:
            guard let xdvURL,
                  let pageAsset = pageAssetsByNumber[pageNumber]
            else { return }
            syncTargetURL = xdvURL
            x = pageAsset.viewBox.minX + max(0, min(1, xNorm)) * pageAsset.viewBox.width
            y = pageAsset.viewBox.minY + max(0, min(1, yNorm)) * pageAsset.viewBox.height
        case .pdfNative:
            guard let pdfURL else { return }
            syncTargetURL = pdfURL
            x = xNorm
            y = yNorm
        }

        renderQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.resolveSyncTeX(pageNumber: pageNumber, x: x, y: y, documentURL: syncTargetURL)
                DispatchQueue.main.async {
                    self.statusLabel.stringValue = "Reverse lookup: \(result.input) : \(result.line)"
                }
                let template = self.customReverseCommandTemplate ?? self.reverseLookupTarget.commandTemplate
                try self.runReverseCommand(template: template, result: result, pageNumber: pageNumber, x: x, y: y, documentURL: syncTargetURL)
            } catch {
                DispatchQueue.main.async {
                    self.statusLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    private func requestedPageNumbers() -> [Int] {
        let start = spreadStart(for: currentPage) + 1
        if spread == 2 {
            return [start, min(start + 1, max(totalPages, start))].filter { $0 >= 1 }
        }
        return [start]
    }

    private func showVisiblePagesOrRender() {
        let missingPages = requestedPageNumbers().filter { pageAssetsByNumber[$0] == nil }
        if missingPages.isEmpty {
            presentVisiblePages(displayName: currentDisplayName)
        } else {
            scheduleRender()
        }
    }

    private func loadViewerShell() {
        loadingViewerShell = true
        viewerShellReady = false
        let html = """
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body { margin: 0; padding: 0; background: #ffffff; }
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            .stage { padding: 24px; display: flex; justify-content: center; }
            .pages { display: flex; gap: 24px; align-items: flex-start; justify-content: center; width: 100%; }
            .page-base { display: block; background: transparent; box-shadow: none; }
          </style>
        </head>
        <body>
          <div class="stage">
            <div id="pages" class="pages"></div>
          </div>
          <script>
            const pagesRoot = document.getElementById('pages');
            pagesRoot.addEventListener('click', (event) => {
              const img = event.target.closest('img.page-base[data-page]');
              if (!img) return;
              if (!event.metaKey) return;
              const rect = img.getBoundingClientRect();
              if (rect.width <= 0 || rect.height <= 0) return;
              const xNorm = (event.clientX - rect.left) / rect.width;
              const yNorm = (event.clientY - rect.top) / rect.height;
              window.webkit.messageHandlers.reverseLookup.postMessage({
                page: Number(img.dataset.page),
                xNorm,
                yNorm
              });
            });
            let preloadImage = (src) => new Promise((resolve) => {
              const image = new Image();
              image.onload = () => resolve();
              image.onerror = () => resolve();
              image.src = src;
            });
            let stateVersion = 0;
            window.__setViewerState = async (state) => {
              const version = ++stateVersion;
              const wrapper = document.createElement('div');
              wrapper.innerHTML = state.htmlPages || '';
              const sources = Array.from(wrapper.querySelectorAll('img')).map((img) => img.src);
              await Promise.all(sources.map(preloadImage));
              if (version !== stateVersion) return;
              pagesRoot.className = state.containerClass || 'pages';
              pagesRoot.innerHTML = state.htmlPages || '';
            };
          </script>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: pipeline?.outputRoot)
    }

    private func updateViewerState(htmlPages: String, containerClass: String) {
        let payload: [String: String] = [
            "htmlPages": htmlPages,
            "containerClass": containerClass,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }

        let script = "window.__setViewerState(\(json));"
        if viewerShellReady {
            webView.evaluateJavaScript(script, completionHandler: nil)
        } else {
            pendingViewerStateScript = script
            if !loadingViewerShell {
                loadViewerShell()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if loadingViewerShell {
            loadingViewerShell = false
            viewerShellReady = true
            if let script = pendingViewerStateScript {
                pendingViewerStateScript = nil
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
        }
    }

    private func resolveSyncTeX(pageNumber: Int, x: Double, y: Double, documentURL: URL) throws -> SyncTeXResult {
        guard let pipeline else {
            throw ViewerError.missingSource("No document is open.")
        }
        guard pipeline.which("synctex") != nil else {
            throw ViewerError.missingTool("synctex")
        }
        let output = try pipeline.runProcess(
            executable: "synctex",
            arguments: ["edit", "-o", "\(pageNumber):\(x):\(y):\(documentURL.path)"],
            directory: documentURL.deletingLastPathComponent()
        )
        guard output.exitCode == 0 else {
            let message = output.stderr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty ? output.stdout : output.stderr
            throw ViewerError.processFailed("synctex failed:\n\(message.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))")
        }
        guard let result = SyncTeXResult.parse(output.stdout) else {
            throw ViewerError.processFailed("Could not parse SyncTeX reverse lookup result.")
        }
        return result
    }

    private func runReverseCommand(template: String, result: SyncTeXResult, pageNumber: Int, x: Double, y: Double, documentURL: URL) throws {
        guard let pipeline else {
            throw ViewerError.missingSource("No document is open.")
        }
        let replacements: [String: String] = [
            "{input}": shellEscape(result.input),
            "{line}": String(result.line),
            "{column}": String(result.column),
            "{page}": String(pageNumber),
            "{x}": String(x),
            "{y}": String(y),
            "{xdv}": shellEscape((xdvURL ?? documentURL).path),
        ]

        let command = replacements.reduce(template) { partial, pair in
            partial.replacingOccurrences(of: pair.key, with: pair.value)
        }

        let output = try pipeline.runProcess(
            executable: "/bin/zsh",
            arguments: ["-lc", command],
            directory: documentURL.deletingLastPathComponent()
        )
        guard output.exitCode == 0 else {
            let message = output.stderr.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty ? output.stdout : output.stderr
            throw ViewerError.processFailed("Reverse command failed:\n\(message.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))")
        }
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct SyncTeXResult {
    let input: String
    let line: Int
    let column: Int

    static func parse(_ output: String) -> SyncTeXResult? {
        var input: String?
        var line: Int?
        var column: Int?

        for rawLine in output.split(separator: "\n") {
            let lineText = String(rawLine)
            if lineText.hasPrefix("Input:") {
                input = String(lineText.dropFirst("Input:".count))
            } else if lineText.hasPrefix("Line:") {
                line = Int(lineText.dropFirst("Line:".count))
            } else if lineText.hasPrefix("Column:") {
                column = Int(lineText.dropFirst("Column:".count))
            }
        }

        guard let input, let line, let column else { return nil }
        let normalizedInput = URL(fileURLWithPath: input).standardizedFileURL.path
        let normalizedLine = max(line, 1)
        let normalizedColumn = max(column, 1)
        return SyncTeXResult(input: normalizedInput, line: normalizedLine, column: normalizedColumn)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: ViewerWindowController?
    private let configuration: AppConfiguration

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        let controller = ViewerWindowController(configuration: configuration)
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installMenus() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About XDV Native Viewer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit XDV Native Viewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        let openItem = NSMenuItem(title: "Open...", action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        let closeItem = NSMenuItem(title: "Close", action: #selector(closeWindow(_:)), keyEquivalent: "w")
        closeItem.target = self
        fileMenu.addItem(closeItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openDocument(_ sender: Any?) {
        windowController?.openDocumentPanel(sender)
    }

    @objc private func closeWindow(_ sender: Any?) {
        windowController?.closeDocumentWindow(sender)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
var reverseCommandTemplate: String?
var inputArgument: String?
var backend: RenderBackend = .pdfNative
var showFigures = false
var reverseLookupTarget: ReverseLookupTarget = .cursor

var index = 0
while index < arguments.count {
    let argument = arguments[index]
    if argument == "--reverse-command" {
        index += 1
        guard index < arguments.count else {
            fputs("Missing value for --reverse-command\n", stderr)
            exit(1)
        }
        reverseCommandTemplate = arguments[index]
    } else if argument == "--pdf-native" {
        backend = .pdfNative
    } else if argument == "--xdv-svg" {
        backend = .xdvSVG
    } else if argument == "--hide-figures" {
        showFigures = false
    } else if argument == "--show-figures" {
        showFigures = true
    } else if argument == "--synctex-code" {
        reverseLookupTarget = .code
    } else if argument == "--synctex-cursor" {
        reverseLookupTarget = .cursor
    } else if inputArgument == nil {
        inputArgument = argument
    } else {
        fputs("Unexpected argument: \(argument)\n", stderr)
        exit(1)
    }
    index += 1
}

let inputURL = inputArgument.map {
    URL(
        fileURLWithPath: $0,
        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ).standardizedFileURL
}

let app = NSApplication.shared
let configuration = AppConfiguration(
    inputURL: inputURL,
    reverseCommandTemplate: reverseCommandTemplate,
    backend: backend,
    showFigures: showFigures,
    reverseLookupTarget: reverseLookupTarget
)
let delegate = AppDelegate(configuration: configuration)
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
