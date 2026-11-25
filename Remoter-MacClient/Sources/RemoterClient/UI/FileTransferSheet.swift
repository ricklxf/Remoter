import AppKit

/// Dual-pane bidirectional file manager & transfer window:
/// - Left pane:  Local filesystem browser (path bar, up-dir, multi-select, upload selected files/folders recursively to current remote dir)
/// - Right pane: Remote filesystem browser (path bar, up-dir, multi-select, download selected files/folders recursively to current local dir)
/// - Bottom bar: Live transfer progress, resumable transfer (`[断点续传]`) indicator, and transfer history.
public final class FileTransferSheetController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private struct LocalFileEntry {
        let url: URL
        let name: String
        let size: Int64
        let isDir: Bool
        let modifiedDate: Date?
    }

    private weak var connection: RemoterConnection?
    private var isWindowsHost: Bool = false

    // Local pane state
    private var currentLocalURL: URL
    private var localEntries: [LocalFileEntry] = []

    // Remote pane state
    private var currentRemotePath: String = ""
    private var remoteEntries: [RemoteFileEntry] = []

    // Transfer state
    private var transfers: [FileTransferProgress] = []

    // Local pane controls
    private let localPathLabel = Theme.makeLabel("~", size: 11.5, weight: .medium, color: Theme.textPrimary, monospaced: true)
    private let localUpButton = Theme.makeButton(title: "↑", style: .secondary, fontSize: 12)
    private let localRefreshButton = Theme.makeButton(title: "刷新", style: .secondary, fontSize: 11.5)
    private let localUploadSelectedButton = Theme.makeButton(title: "上传选中 →", style: .primary, fontSize: 11.5, weight: .semibold)
    private let localTable = NSTableView()
    private let localEmptyLabel = Theme.makeLabel("此目录为空", size: 12, color: Theme.textMuted)

    // Remote pane controls
    private let remotePathLabel = Theme.makeLabel("/", size: 11.5, weight: .medium, color: Theme.textPrimary, monospaced: true)
    private let remoteUpButton = Theme.makeButton(title: "↑", style: .secondary, fontSize: 12)
    private let remoteRefreshButton = Theme.makeButton(title: "刷新", style: .secondary, fontSize: 11.5)
    private let remoteDownloadSelectedButton = Theme.makeButton(title: "← 下载选中", style: .primary, fontSize: 11.5, weight: .semibold)
    private let pickUploadButton = Theme.makeButton(title: "选择上传…", style: .secondary, fontSize: 11.5)
    private let remoteTable = NSTableView()
    private let remoteEmptyLabel = Theme.makeLabel("目录为空或正在加载…", size: 12, color: Theme.textMuted)

    // Transfer progress & history controls
    private let progressBar = NSProgressIndicator()
    private let progressLabel = Theme.makeLabel("支持双栏互传、文件夹递归上传/下载与断点续传（也可直接拖拽文件或文件夹到远程桌面）", size: 11.5, color: Theme.textMuted)
    private let transferTable = NSTableView()

    // Bottom bar
    private let openLocalDirButton = Theme.makeButton(title: "在 Finder 中打开本地目录", style: .ghost, fontSize: 11.5)
    private let openDownloadsButton = Theme.makeButton(title: "打开默认下载目录", style: .ghost, fontSize: 11.5)
    private let closeButton = Theme.makeButton(title: "关闭", style: .secondary, fontSize: 12)

    public var onUploadError: ((String) -> Void)?

    public init(connection: RemoterConnection) {
        self.connection = connection
        self.isWindowsHost = connection.serverOs.lowercased().contains("win")
        self.currentLocalURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "文件管理器 — 双向文件传输"
        window.appearance = Theme.darkAppearance
        window.backgroundColor = Theme.background
        window.minSize = NSSize(width: 760, height: 480)
        super.init(window: window)

        buildUI()
        reloadLocalDirectory()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Updates

    public func requestInitialDirectory() {
        reloadLocalDirectory()
        requestRemoteDirectory(currentRemotePath)
    }

    public func handleDirListing(path: String, entries: [RemoteFileEntry]) {
        currentRemotePath = path
        remotePathLabel.stringValue = path.isEmpty ? "/" : path
        self.remoteEntries = entries.sorted { lhs, rhs in
            if lhs.isDir != rhs.isDir { return lhs.isDir && !rhs.isDir }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        remoteTable.reloadData()
        remoteEmptyLabel.isHidden = !self.remoteEntries.isEmpty
        if self.remoteEntries.isEmpty {
            remoteEmptyLabel.stringValue = "此目录为空"
        }
        updateActionButtonsState()
    }

    public func updateTransferProgress(_ progress: FileTransferProgress) {
        if let idx = transfers.firstIndex(where: { $0.id == progress.id }) {
            transfers[idx] = progress
        } else {
            transfers.insert(progress, at: 0)
            if transfers.count > 60 {
                transfers.removeLast()
            }
        }
        transferTable.reloadData()

        if let active = transfers.first(where: { !$0.done }) ?? transfers.first {
            progressBar.doubleValue = active.fractionCompleted * 100.0
            let arrow = active.direction == .upload ? "↑ 上传" : "↓ 下载"
            let resumeTag = active.resumed ? " [断点续传]" : ""
            if let err = active.error {
                progressLabel.stringValue = "\(arrow)\(resumeTag) 失败: \(active.name) — \(err)"
                progressLabel.textColor = Theme.danger
            } else if active.done {
                let extra = active.savedPath.map { " → \($0)" } ?? ""
                progressLabel.stringValue = "\(arrow)\(resumeTag) 完成: \(active.name)\(extra)"
                progressLabel.textColor = Theme.accent
            } else {
                let pct = Int(active.fractionCompleted * 100)
                let spd = Theme.formatSpeed(active.speedBps)
                let spdPart = spd.isEmpty ? "" : " · \(spd)"
                progressLabel.stringValue = "\(arrow)\(resumeTag) \(active.name) (\(pct)% · \(Theme.formatBytes(active.transferred)) / \(Theme.formatBytes(active.size))\(spdPart))"
                progressLabel.textColor = Theme.textPrimary
            }
        }
    }

    // MARK: - UI Setup

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = Theme.background.cgColor

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let leftPane = buildLocalPane()
        let rightPane = buildRemotePane()
        splitView.addArrangedSubview(leftPane)
        splitView.addArrangedSubview(rightPane)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        // Bottom transfer progress & history card
        let transferCard = Theme.makeCard(background: Theme.surface, cornerRadius: 10)

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.style = .bar
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        setupTransferTable()
        let transferScroll = NSScrollView()
        transferScroll.documentView = transferTable
        transferScroll.drawsBackground = false
        transferScroll.hasVerticalScroller = true
        transferScroll.autohidesScrollers = true
        transferScroll.borderType = .noBorder
        transferScroll.translatesAutoresizingMaskIntoConstraints = false

        transferCard.addSubview(progressLabel)
        transferCard.addSubview(progressBar)
        transferCard.addSubview(transferScroll)

        NSLayoutConstraint.activate([
            progressLabel.leadingAnchor.constraint(equalTo: transferCard.leadingAnchor, constant: 12),
            progressLabel.trailingAnchor.constraint(equalTo: transferCard.trailingAnchor, constant: -12),
            progressLabel.topAnchor.constraint(equalTo: transferCard.topAnchor, constant: 8),

            progressBar.leadingAnchor.constraint(equalTo: transferCard.leadingAnchor, constant: 12),
            progressBar.trailingAnchor.constraint(equalTo: transferCard.trailingAnchor, constant: -12),
            progressBar.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 6),

            transferScroll.leadingAnchor.constraint(equalTo: transferCard.leadingAnchor, constant: 6),
            transferScroll.trailingAnchor.constraint(equalTo: transferCard.trailingAnchor, constant: -6),
            transferScroll.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 6),
            transferScroll.bottomAnchor.constraint(equalTo: transferCard.bottomAnchor, constant: -6),
        ])

        // Bottom action bar
        openLocalDirButton.target = self
        openLocalDirButton.action = #selector(openLocalDirTapped)
        openDownloadsButton.target = self
        openDownloadsButton.action = #selector(openDownloadsTapped)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let bottomBar = NSStackView(views: [openLocalDirButton, openDownloadsButton, spacer, closeButton])
        bottomBar.orientation = .horizontal
        bottomBar.alignment = .centerY
        bottomBar.spacing = 10
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        openLocalDirButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        openDownloadsButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        closeButton.widthAnchor.constraint(equalToConstant: 70).isActive = true

        contentView.addSubview(splitView)
        contentView.addSubview(transferCard)
        contentView.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            splitView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            splitView.bottomAnchor.constraint(equalTo: transferCard.topAnchor, constant: -10),

            leftPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            rightPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),

            transferCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            transferCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            transferCard.heightAnchor.constraint(equalToConstant: 148),
            transferCard.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -10),

            bottomBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            bottomBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            bottomBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])

        DispatchQueue.main.async {
            splitView.setPosition(460, ofDividerAt: 0)
        }
    }

    private func buildLocalPane() -> NSView {
        let pane = Theme.makeCard(background: Theme.surface, cornerRadius: 10)

        let title = Theme.makeLabel("本地文件", size: 12.5, weight: .semibold, color: Theme.textPrimary)
        localUpButton.target = self
        localUpButton.action = #selector(localGoUpTapped)
        localRefreshButton.target = self
        localRefreshButton.action = #selector(localRefreshTapped)
        localUploadSelectedButton.target = self
        localUploadSelectedButton.action = #selector(localUploadSelectedTapped)
        localUploadSelectedButton.isEnabled = false

        let headerSpacer = NSView()
        headerSpacer.translatesAutoresizingMaskIntoConstraints = false
        let headerRow = NSStackView(views: [title, headerSpacer, localUploadSelectedButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        localUploadSelectedButton.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let pathCard = Theme.makeCard(background: Theme.inputBackground, cornerRadius: 6)
        localPathLabel.lineBreakMode = .byTruncatingMiddle
        pathCard.addSubview(localPathLabel)
        NSLayoutConstraint.activate([
            localPathLabel.leadingAnchor.constraint(equalTo: pathCard.leadingAnchor, constant: 8),
            localPathLabel.trailingAnchor.constraint(equalTo: pathCard.trailingAnchor, constant: -8),
            localPathLabel.centerYAnchor.constraint(equalTo: pathCard.centerYAnchor),
            pathCard.heightAnchor.constraint(equalToConstant: 26),
        ])

        let pathRow = NSStackView(views: [localUpButton, pathCard, localRefreshButton])
        pathRow.orientation = .horizontal
        pathRow.alignment = .centerY
        pathRow.spacing = 6
        pathRow.translatesAutoresizingMaskIntoConstraints = false
        localUpButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        localUpButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        localRefreshButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        localRefreshButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        pathCard.setContentHuggingPriority(.defaultLow, for: .horizontal)

        setupBrowserTable(localTable, doubleAction: #selector(localRowDoubleClicked))
        let scroll = NSScrollView()
        scroll.documentView = localTable
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        pane.addSubview(headerRow)
        pane.addSubview(pathRow)
        pane.addSubview(scroll)
        pane.addSubview(localEmptyLabel)

        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 10),
            headerRow.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -10),
            headerRow.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),

            pathRow.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 10),
            pathRow.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -10),
            pathRow.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 6),

            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: pathRow.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -6),

            localEmptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            localEmptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        return pane
    }

    private func buildRemotePane() -> NSView {
        let pane = Theme.makeCard(background: Theme.surface, cornerRadius: 10)

        let title = Theme.makeLabel("远端文件", size: 12.5, weight: .semibold, color: Theme.textPrimary)
        remoteUpButton.target = self
        remoteUpButton.action = #selector(remoteGoUpTapped)
        remoteRefreshButton.target = self
        remoteRefreshButton.action = #selector(remoteRefreshTapped)
        remoteDownloadSelectedButton.target = self
        remoteDownloadSelectedButton.action = #selector(remoteDownloadSelectedTapped)
        remoteDownloadSelectedButton.isEnabled = false
        pickUploadButton.target = self
        pickUploadButton.action = #selector(pickUploadTapped)

        let headerSpacer = NSView()
        headerSpacer.translatesAutoresizingMaskIntoConstraints = false
        let headerRow = NSStackView(views: [title, headerSpacer, remoteDownloadSelectedButton, pickUploadButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 6
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        remoteDownloadSelectedButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        pickUploadButton.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let pathCard = Theme.makeCard(background: Theme.inputBackground, cornerRadius: 6)
        remotePathLabel.lineBreakMode = .byTruncatingMiddle
        pathCard.addSubview(remotePathLabel)
        NSLayoutConstraint.activate([
            remotePathLabel.leadingAnchor.constraint(equalTo: pathCard.leadingAnchor, constant: 8),
            remotePathLabel.trailingAnchor.constraint(equalTo: pathCard.trailingAnchor, constant: -8),
            remotePathLabel.centerYAnchor.constraint(equalTo: pathCard.centerYAnchor),
            pathCard.heightAnchor.constraint(equalToConstant: 26),
        ])

        let pathRow = NSStackView(views: [remoteUpButton, pathCard, remoteRefreshButton])
        pathRow.orientation = .horizontal
        pathRow.alignment = .centerY
        pathRow.spacing = 6
        pathRow.translatesAutoresizingMaskIntoConstraints = false
        remoteUpButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        remoteUpButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        remoteRefreshButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        remoteRefreshButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        pathCard.setContentHuggingPriority(.defaultLow, for: .horizontal)

        setupBrowserTable(remoteTable, doubleAction: #selector(remoteRowDoubleClicked))
        let scroll = NSScrollView()
        scroll.documentView = remoteTable
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        pane.addSubview(headerRow)
        pane.addSubview(pathRow)
        pane.addSubview(scroll)
        pane.addSubview(remoteEmptyLabel)

        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 10),
            headerRow.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -10),
            headerRow.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),

            pathRow.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 10),
            pathRow.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -10),
            pathRow.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 6),

            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: pathRow.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -6),

            remoteEmptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            remoteEmptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        return pane
    }

    private func setupBrowserTable(_ table: NSTableView, doubleAction: Selector) {
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "名称"
        nameCol.width = 210
        nameCol.minWidth = 120

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "大小"
        sizeCol.width = 76

        let modCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("modified"))
        modCol.title = "修改时间"
        modCol.width = 124

        table.addTableColumn(nameCol)
        table.addTableColumn(sizeCol)
        table.addTableColumn(modCol)
        table.backgroundColor = .clear
        table.rowHeight = 25
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = doubleAction
    }

    private func setupTransferTable() {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transfer"))
        col.title = "传输记录"
        col.resizingMask = .autoresizingMask
        transferTable.addTableColumn(col)
        transferTable.headerView = nil
        transferTable.backgroundColor = .clear
        transferTable.rowHeight = 22
        transferTable.dataSource = self
        transferTable.delegate = self
    }

    // MARK: - Local Directory Loading

    private func reloadLocalDirectory() {
        localPathLabel.stringValue = currentLocalURL.path
        let fm = FileManager.default
        var list: [LocalFileEntry] = []
        if let urls = try? fm.contentsOfDirectory(
            at: currentLocalURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for u in urls {
                let rv = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDir = rv?.isDirectory ?? false
                let size = Int64(rv?.fileSize ?? 0)
                list.append(LocalFileEntry(
                    url: u,
                    name: u.lastPathComponent,
                    size: size,
                    isDir: isDir,
                    modifiedDate: rv?.contentModificationDate
                ))
            }
        }
        localEntries = list.sorted { lhs, rhs in
            if lhs.isDir != rhs.isDir { return lhs.isDir && !rhs.isDir }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        localTable.reloadData()
        localEmptyLabel.isHidden = !localEntries.isEmpty
        updateActionButtonsState()
    }

    private func requestRemoteDirectory(_ path: String) {
        remoteEmptyLabel.stringValue = "正在加载目录…"
        remoteEmptyLabel.isHidden = !remoteEntries.isEmpty
        connection?.sendListDir(path: path)
    }

    // MARK: - Actions

    @objc private func localGoUpTapped() {
        let parent = currentLocalURL.deletingLastPathComponent()
        if parent.path != currentLocalURL.path {
            currentLocalURL = parent
            reloadLocalDirectory()
        }
    }

    @objc private func localRefreshTapped() {
        reloadLocalDirectory()
    }

    @objc private func localRowDoubleClicked() {
        let row = localTable.clickedRow
        guard row >= 0, row < localEntries.count else { return }
        let entry = localEntries[row]
        if entry.isDir {
            currentLocalURL = entry.url
            reloadLocalDirectory()
        } else {
            uploadLocalURLs([entry.url])
        }
    }

    @objc private func localUploadSelectedTapped() {
        let rows = localTable.selectedRowIndexes
        guard !rows.isEmpty else { return }
        let urls = rows.compactMap { idx -> URL? in
            guard idx >= 0, idx < localEntries.count else { return nil }
            return localEntries[idx].url
        }
        uploadLocalURLs(urls)
    }

    private func uploadLocalURLs(_ urls: [URL]) {
        guard !urls.isEmpty, let conn = connection else { return }
        let targetRemoteDir = currentRemotePath.isEmpty ? nil : currentRemotePath
        Task { [weak self] in
            do {
                _ = try await conn.uploadItems(at: urls, destDir: targetRemoteDir, resume: true)
                await MainActor.run {
                    self?.requestRemoteDirectory(self?.currentRemotePath ?? "")
                }
            } catch {
                await MainActor.run {
                    self?.onUploadError?("上传失败: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func remoteGoUpTapped() {
        guard !currentRemotePath.isEmpty else {
            requestRemoteDirectory("")
            return
        }
        requestRemoteDirectory(parentPath(of: currentRemotePath))
    }

    @objc private func remoteRefreshTapped() {
        requestRemoteDirectory(currentRemotePath)
    }

    @objc private func pickUploadTapped() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "上传"
        guard let win = window else { return }
        panel.beginSheetModal(for: win) { [weak self] response in
            guard response == .OK, let self else { return }
            self.uploadLocalURLs(panel.urls)
        }
    }

    @objc private func remoteRowDoubleClicked() {
        let row = remoteTable.clickedRow
        guard row >= 0, row < remoteEntries.count else { return }
        let entry = remoteEntries[row]
        let fullPath = joinPath(currentRemotePath, entry.name)
        if entry.isDir {
            requestRemoteDirectory(fullPath)
        } else {
            downloadRemoteEntries([entry])
        }
    }

    @objc private func remoteDownloadSelectedTapped() {
        let rows = remoteTable.selectedRowIndexes
        guard !rows.isEmpty else { return }
        let selected = rows.compactMap { idx -> RemoteFileEntry? in
            guard idx >= 0, idx < remoteEntries.count else { return nil }
            return remoteEntries[idx]
        }
        downloadRemoteEntries(selected)
    }

    private func downloadRemoteEntries(_ selected: [RemoteFileEntry]) {
        guard !selected.isEmpty, let conn = connection else { return }
        let localDir = currentLocalURL
        let baseRemote = currentRemotePath
        Task { [weak self] in
            for entry in selected {
                let fullPath = self?.joinPath(baseRemote, entry.name) ?? entry.name
                do {
                    if entry.isDir {
                        _ = try await conn.downloadDirectory(remotePath: fullPath, to: localDir)
                    } else {
                        let safeName = FileTransferClient.sanitizeFileName(entry.name)
                        let targetURL = localDir.appendingPathComponent(safeName)
                        _ = try await conn.downloadFile(remotePath: fullPath, to: targetURL, overwriteExisting: true)
                    }
                    await MainActor.run {
                        self?.reloadLocalDirectory()
                    }
                } catch {
                    await MainActor.run {
                        self?.onUploadError?("下载失败 (\(entry.name)): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    @objc private func openLocalDirTapped() {
        NSWorkspace.shared.open(currentLocalURL)
    }

    @objc private func openDownloadsTapped() {
        if let dir = connection?.fileTransfer.downloadDirectory {
            NSWorkspace.shared.open(dir)
        }
    }

    @objc private func closeTapped() {
        if let win = window, let parent = win.sheetParent {
            parent.endSheet(win)
        } else {
            window?.close()
        }
    }

    private func updateActionButtonsState() {
        let localCount = localTable.selectedRowIndexes.count
        localUploadSelectedButton.isEnabled = localCount > 0
        localUploadSelectedButton.title = localCount > 1 ? "上传选中 (\(localCount)) →" : "上传选中 →"

        let remoteCount = remoteTable.selectedRowIndexes.count
        remoteDownloadSelectedButton.isEnabled = remoteCount > 0
        remoteDownloadSelectedButton.title = remoteCount > 1 ? "← 下载选中 (\(remoteCount))" : "← 下载选中"
    }

    // MARK: - Path Helpers

    private func joinPath(_ base: String, _ name: String) -> String {
        if base.isEmpty { return name }
        let sep = (isWindowsHost || base.contains("\\")) ? "\\" : "/"
        if base.hasSuffix(sep) { return base + name }
        return base + sep + name
    }

    private func parentPath(of path: String) -> String {
        let isWin = isWindowsHost || path.contains("\\")
        let sep: Character = isWin ? "\\" : "/"
        var trimmed = path
        while trimmed.count > 1 && trimmed.last == sep {
            trimmed.removeLast()
        }
        if isWin && trimmed.count == 2 && trimmed.last == ":" {
            return ""
        }
        guard let idx = trimmed.lastIndex(of: sep) else {
            return ""
        }
        let prefix = String(trimmed[..<idx])
        if prefix.isEmpty {
            return isWin ? "" : "/"
        }
        if isWin && prefix.count == 2 && prefix.last == ":" {
            return prefix + "\\"
        }
        return prefix
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

    // MARK: - NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === localTable { return localEntries.count }
        if tableView === remoteTable { return remoteEntries.count }
        return transfers.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === localTable {
            guard row >= 0, row < localEntries.count, let colId = tableColumn?.identifier.rawValue else { return nil }
            let entry = localEntries[row]
            let cell = makeBrowserCell(tableView: tableView, colId: colId, prefix: "LocalCell")
            switch colId {
            case "name":
                cell.textField?.stringValue = (entry.isDir ? "📁 " : "📄 ") + entry.name
                cell.textField?.textColor = entry.isDir ? Theme.accent : Theme.textPrimary
            case "size":
                cell.textField?.stringValue = entry.isDir ? "--" : Theme.formatBytes(entry.size)
                cell.textField?.textColor = Theme.textMuted
            case "modified":
                cell.textField?.stringValue = entry.modifiedDate.map { Self.dateFormatter.string(from: $0) } ?? "--"
                cell.textField?.textColor = Theme.textMuted
            default:
                break
            }
            return cell
        } else if tableView === remoteTable {
            guard row >= 0, row < remoteEntries.count, let colId = tableColumn?.identifier.rawValue else { return nil }
            let entry = remoteEntries[row]
            let cell = makeBrowserCell(tableView: tableView, colId: colId, prefix: "RemoteCell")
            switch colId {
            case "name":
                cell.textField?.stringValue = (entry.isDir ? "📁 " : "📄 ") + entry.name
                cell.textField?.textColor = entry.isDir ? Theme.accent : Theme.textPrimary
            case "size":
                cell.textField?.stringValue = entry.isDir ? "--" : Theme.formatBytes(entry.size)
                cell.textField?.textColor = Theme.textMuted
            case "modified":
                if entry.modifiedMs > 0 {
                    let date = Date(timeIntervalSince1970: Double(entry.modifiedMs) / 1000.0)
                    cell.textField?.stringValue = Self.dateFormatter.string(from: date)
                } else {
                    cell.textField?.stringValue = "--"
                }
                cell.textField?.textColor = Theme.textMuted
            default:
                break
            }
            return cell
        } else {
            guard row >= 0, row < transfers.count else { return nil }
            let item = transfers[row]
            let cellId = NSUserInterfaceItemIdentifier("TransferRowCell")
            let cell = (tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = cellId
                let tf = Theme.makeLabel("", size: 11.5, color: Theme.textPrimary, monospaced: true)
                c.textField = tf
                c.addSubview(tf)
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()

            let dir = item.direction == .upload ? "↑" : "↓"
            let resumeBadge = item.resumed ? "[续传] " : ""
            if let err = item.error {
                cell.textField?.stringValue = "\(dir) \(resumeBadge)\(item.name) — 失败: \(err)"
                cell.textField?.textColor = Theme.danger
            } else if item.done {
                cell.textField?.stringValue = "\(dir) \(resumeBadge)\(item.name) (\(Theme.formatBytes(item.size))) — 完成"
                cell.textField?.textColor = Theme.accent
            } else {
                let pct = Int(item.fractionCompleted * 100)
                let spd = Theme.formatSpeed(item.speedBps)
                cell.textField?.stringValue = "\(dir) \(resumeBadge)\(item.name) — \(pct)% \(spd)"
                cell.textField?.textColor = Theme.textPrimary
            }
            return cell
        }
    }

    private func makeBrowserCell(tableView: NSTableView, colId: String, prefix: String) -> NSTableCellView {
        let cellId = NSUserInterfaceItemIdentifier("\(prefix)_\(colId)")
        return (tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = cellId
            let tf = Theme.makeLabel("", size: 11.5, color: Theme.textPrimary)
            tf.lineBreakMode = .byTruncatingMiddle
            c.textField = tf
            c.addSubview(tf)
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionButtonsState()
    }
}
