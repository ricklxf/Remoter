import AppKit

/// Remote file browser & bidirectional file transfer sheet/window.
/// Supports browsing remote directories (`connection.sendListDir`), downloading files
/// (`connection.sendRequestFile`), uploading local files (`NSOpenPanel` -> `connection.uploadFile(at:)`),
/// and displaying live `FileTransferProgress` status.
public final class FileTransferSheetController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private weak var connection: RemoterConnection?
    private var currentPath: String = ""
    private var entries: [RemoteFileEntry] = []
    private var transfers: [FileTransferProgress] = []
    private var isWindowsHost: Bool = false

    private let pathLabel = Theme.makeLabel("/", size: 12, weight: .medium, color: Theme.textPrimary, monospaced: true)
    private let upButton = Theme.makeButton(title: "↑ 上级", style: .secondary, fontSize: 12)
    private let refreshButton = Theme.makeButton(title: "刷新", style: .secondary, fontSize: 12)
    private let uploadButton = Theme.makeButton(title: "上传文件…", style: .primary, fontSize: 12, weight: .semibold)
    private let downloadButton = Theme.makeButton(title: "下载选中", style: .secondary, fontSize: 12)
    private let openDownloadsButton = Theme.makeButton(title: "打开下载目录", style: .ghost, fontSize: 11.5)
    private let closeButton = Theme.makeButton(title: "关闭", style: .secondary, fontSize: 12)

    private let fileTable = NSTableView()
    private let emptyLabel = Theme.makeLabel("目录为空或正在加载…", size: 12.5, color: Theme.textMuted)

    private let progressBar = NSProgressIndicator()
    private let progressLabel = Theme.makeLabel("拖拽文件到远程桌面或点击「上传文件」开始传输", size: 11.5, color: Theme.textMuted)
    private let transferTable = NSTableView()

    public var onUploadError: ((String) -> Void)?

    public init(connection: RemoterConnection) {
        self.connection = connection
        self.isWindowsHost = connection.serverOs.lowercased().contains("win")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "文件传输"
        window.appearance = Theme.darkAppearance
        window.backgroundColor = Theme.background
        window.minSize = NSSize(width: 560, height: 420)
        super.init(window: window)

        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Updates

    public func requestInitialDirectory() {
        requestDirectory(currentPath)
    }

    public func handleDirListing(path: String, entries: [RemoteFileEntry]) {
        currentPath = path
        pathLabel.stringValue = path.isEmpty ? "/" : path
        self.entries = entries.sorted { lhs, rhs in
            if lhs.isDir != rhs.isDir { return lhs.isDir && !rhs.isDir }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        fileTable.reloadData()
        emptyLabel.isHidden = !self.entries.isEmpty
        if self.entries.isEmpty {
            emptyLabel.stringValue = "此目录为空"
        }
        updateDownloadButtonState()
    }

    public func updateTransferProgress(_ progress: FileTransferProgress) {
        if let idx = transfers.firstIndex(where: { $0.id == progress.id }) {
            transfers[idx] = progress
        } else {
            transfers.insert(progress, at: 0)
            if transfers.count > 40 {
                transfers.removeLast()
            }
        }
        transferTable.reloadData()

        if let active = transfers.first(where: { !$0.done }) ?? transfers.first {
            progressBar.doubleValue = active.fractionCompleted * 100.0
            let arrow = active.direction == .upload ? "↑ 上传" : "↓ 下载"
            if let err = active.error {
                progressLabel.stringValue = "\(arrow) 失败: \(active.name) — \(err)"
                progressLabel.textColor = Theme.danger
            } else if active.done {
                let extra = active.savedPath.map { " → \($0)" } ?? ""
                progressLabel.stringValue = "\(arrow) 完成: \(active.name)\(extra)"
                progressLabel.textColor = Theme.accent
            } else {
                let pct = Int(active.fractionCompleted * 100)
                let spd = Theme.formatSpeed(active.speedBps)
                let spdPart = spd.isEmpty ? "" : " · \(spd)"
                progressLabel.stringValue = "\(arrow) \(active.name) (\(pct)% · \(Theme.formatBytes(active.transferred)) / \(Theme.formatBytes(active.size))\(spdPart))"
                progressLabel.textColor = Theme.textPrimary
            }
        }
    }

    // MARK: - UI Setup

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = Theme.background.cgColor

        // Top toolbar row
        upButton.target = self
        upButton.action = #selector(goUpTapped)
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        uploadButton.target = self
        uploadButton.action = #selector(uploadTapped)
        downloadButton.target = self
        downloadButton.action = #selector(downloadSelectedTapped)
        downloadButton.isEnabled = false

        let pathCard = Theme.makeCard(background: Theme.inputBackground, cornerRadius: 7)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathCard.addSubview(pathLabel)
        NSLayoutConstraint.activate([
            pathLabel.leadingAnchor.constraint(equalTo: pathCard.leadingAnchor, constant: 10),
            pathLabel.trailingAnchor.constraint(equalTo: pathCard.trailingAnchor, constant: -10),
            pathLabel.centerYAnchor.constraint(equalTo: pathCard.centerYAnchor),
            pathCard.heightAnchor.constraint(equalToConstant: 30),
        ])

        let topBar = NSStackView(views: [upButton, pathCard, refreshButton, downloadButton, uploadButton])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false

        upButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        upButton.widthAnchor.constraint(equalToConstant: 66).isActive = true
        refreshButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        refreshButton.widthAnchor.constraint(equalToConstant: 54).isActive = true
        downloadButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        downloadButton.widthAnchor.constraint(equalToConstant: 76).isActive = true
        uploadButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        uploadButton.widthAnchor.constraint(equalToConstant: 86).isActive = true
        pathCard.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Remote file table card
        let fileCard = Theme.makeCard(background: Theme.surface, cornerRadius: 10)
        setupFileTable()

        let fileScroll = NSScrollView()
        fileScroll.documentView = fileTable
        fileScroll.drawsBackground = false
        fileScroll.hasVerticalScroller = true
        fileScroll.autohidesScrollers = true
        fileScroll.borderType = .noBorder
        fileScroll.translatesAutoresizingMaskIntoConstraints = false

        fileCard.addSubview(fileScroll)
        fileCard.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            fileScroll.leadingAnchor.constraint(equalTo: fileCard.leadingAnchor, constant: 6),
            fileScroll.trailingAnchor.constraint(equalTo: fileCard.trailingAnchor, constant: -6),
            fileScroll.topAnchor.constraint(equalTo: fileCard.topAnchor, constant: 6),
            fileScroll.bottomAnchor.constraint(equalTo: fileCard.bottomAnchor, constant: -6),

            emptyLabel.centerXAnchor.constraint(equalTo: fileCard.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: fileCard.centerYAnchor),
        ])

        // Active transfer progress & history card
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

        // Bottom bar
        openDownloadsButton.target = self
        openDownloadsButton.action = #selector(openDownloadsTapped)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let bottomBar = NSStackView(views: [openDownloadsButton, spacer, closeButton])
        bottomBar.orientation = .horizontal
        bottomBar.alignment = .centerY
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        openDownloadsButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        closeButton.widthAnchor.constraint(equalToConstant: 70).isActive = true

        contentView.addSubview(topBar)
        contentView.addSubview(fileCard)
        contentView.addSubview(transferCard)
        contentView.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            topBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),

            fileCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            fileCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            fileCard.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            fileCard.bottomAnchor.constraint(equalTo: transferCard.topAnchor, constant: -10),

            transferCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            transferCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            transferCard.heightAnchor.constraint(equalToConstant: 140),
            transferCard.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -10),

            bottomBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            bottomBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            bottomBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    private func setupFileTable() {
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "名称"
        nameCol.width = 360
        nameCol.minWidth = 180

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "大小"
        sizeCol.width = 100

        let modCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("modified"))
        modCol.title = "修改时间"
        modCol.width = 150

        fileTable.addTableColumn(nameCol)
        fileTable.addTableColumn(sizeCol)
        fileTable.addTableColumn(modCol)
        fileTable.backgroundColor = .clear
        fileTable.rowHeight = 26
        fileTable.usesAlternatingRowBackgroundColors = false
        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.target = self
        fileTable.doubleAction = #selector(fileRowDoubleClicked)
    }

    private func setupTransferTable() {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transfer"))
        col.title = "传输记录"
        col.resizingMask = .autoresizingMask
        transferTable.addTableColumn(col)
        transferTable.headerView = nil
        transferTable.backgroundColor = .clear
        transferTable.rowHeight = 24
        transferTable.dataSource = self
        transferTable.delegate = self
    }

    // MARK: - Actions

    private func requestDirectory(_ path: String) {
        emptyLabel.stringValue = "正在加载目录…"
        emptyLabel.isHidden = !entries.isEmpty
        connection?.sendListDir(path: path)
    }

    @objc private func goUpTapped() {
        guard !currentPath.isEmpty else {
            requestDirectory("")
            return
        }
        let parent = parentPath(of: currentPath)
        requestDirectory(parent)
    }

    @objc private func refreshTapped() {
        requestDirectory(currentPath)
    }

    @objc private func uploadTapped() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "上传"
        guard let win = window else { return }
        panel.beginSheetModal(for: win) { [weak self] response in
            guard response == .OK, let self, let conn = self.connection else { return }
            let urls = panel.urls
            Task {
                for url in urls {
                    do {
                        try await conn.uploadFile(at: url)
                    } catch {
                        await MainActor.run {
                            self.onUploadError?("上传失败 (\(url.lastPathComponent)): \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    @objc private func downloadSelectedTapped() {
        let row = fileTable.selectedRow
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]
        if entry.isDir {
            requestDirectory(joinPath(currentPath, entry.name))
        } else {
            connection?.sendRequestFile(remotePath: joinPath(currentPath, entry.name))
        }
    }

    @objc private func fileRowDoubleClicked() {
        let row = fileTable.clickedRow
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]
        let fullPath = joinPath(currentPath, entry.name)
        if entry.isDir {
            requestDirectory(fullPath)
        } else {
            connection?.sendRequestFile(remotePath: fullPath)
        }
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

    private func updateDownloadButtonState() {
        let row = fileTable.selectedRow
        if row >= 0, row < entries.count {
            downloadButton.isEnabled = true
            downloadButton.title = entries[row].isDir ? "打开目录" : "下载选中"
        } else {
            downloadButton.isEnabled = false
            downloadButton.title = "下载选中"
        }
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
        if tableView === fileTable { return entries.count }
        return transfers.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === fileTable {
            guard row >= 0, row < entries.count, let colId = tableColumn?.identifier.rawValue else { return nil }
            let entry = entries[row]
            let cellId = NSUserInterfaceItemIdentifier("FileCell_\(colId)")
            let cell = (tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = cellId
                let tf = Theme.makeLabel("", size: 12, color: Theme.textPrimary)
                c.textField = tf
                c.addSubview(tf)
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()

            switch colId {
            case "name":
                let prefix = entry.isDir ? "📁 " : "📄 "
                cell.textField?.stringValue = prefix + entry.name
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
            if let err = item.error {
                cell.textField?.stringValue = "\(dir) \(item.name) — 失败: \(err)"
                cell.textField?.textColor = Theme.danger
            } else if item.done {
                cell.textField?.stringValue = "\(dir) \(item.name) (\(Theme.formatBytes(item.size))) — 完成"
                cell.textField?.textColor = Theme.accent
            } else {
                let pct = Int(item.fractionCompleted * 100)
                let spd = Theme.formatSpeed(item.speedBps)
                cell.textField?.stringValue = "\(dir) \(item.name) — \(pct)% \(spd)"
                cell.textField?.textColor = Theme.textPrimary
            }
            return cell
        }
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === fileTable {
            updateDownloadButtonState()
        }
    }
}
