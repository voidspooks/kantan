import AppKit
import Darwin

// MARK: - PTY: forkpty bridge
//
// `forkpty` lives in <util.h>. The Darwin overlay in Swift on macOS does
// expose it, but to keep the build self-contained against future SDK changes
// we also re-declare it via @_silgen_name. swiftc auto-links libSystem on
// macOS, which re-exports libutil — so no extra linker flag is needed.

@_silgen_name("forkpty")
private func _forkpty(_ amaster: UnsafeMutablePointer<Int32>,
                      _ name: UnsafeMutablePointer<CChar>?,
                      _ termp: UnsafeMutablePointer<termios>?,
                      _ winp: UnsafeMutablePointer<winsize>?) -> pid_t

// TIOCSWINSZ = _IOW('t', 103, struct winsize) on macOS. The Darwin module
// usually exposes the symbol but its precise typing varies across SDKs, so we
// pin the value here to avoid the bikeshed.
private let _TIOCSWINSZ: UInt = 0x80087467

// MARK: - Terminal session: PTY + child process

final class TerminalSession {
    private(set) var pid: pid_t = -1
    private(set) var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?

    /// Fires on the main queue with bytes the shell wrote to stdout/stderr.
    var onOutput: ((Data) -> Void)?
    /// Fires on the main queue when the shell process exits or the PTY is closed.
    var onExit: (() -> Void)?

    /// Spawn the user's `$SHELL` (falling back to /bin/zsh) attached to a new
    /// PTY sized to `rows`x`cols`. Returns true on success.
    @discardableResult
    func start(rows: Int, cols: Int) -> Bool {
        guard pid < 0 else { return false }
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // Pre-build all C-string allocations BEFORE forking. After fork()
        // returns 0 in the child, we can only safely call async-signal-safe
        // functions (no malloc, no Swift heap). The child uses the strdup'd
        // pointers directly and then exec's.
        guard let shellC = strdup(shellPath),
              let dashLC = strdup("-l") else {
            return false
        }
        let argv = UnsafeMutableBufferPointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 3)
        argv[0] = shellC
        argv[1] = dashLC
        argv[2] = nil

        var ws = winsize(ws_row: UInt16(max(rows, 1)),
                         ws_col: UInt16(max(cols, 1)),
                         ws_xpixel: 0,
                         ws_ypixel: 0)
        var amaster: Int32 = 0
        let pid = _forkpty(&amaster, nil, nil, &ws)
        if pid < 0 {
            free(shellC); free(dashLC)
            argv.deallocate()
            return false
        }
        if pid == 0 {
            // Child: exec the shell. -l makes it a login shell so PATH/profile load.
            execv(shellC, argv.baseAddress)
            _exit(127)
        }
        // Parent: clean up the staging buffers and start the read loop.
        free(shellC); free(dashLC)
        argv.deallocate()

        self.pid = pid
        self.masterFD = amaster

        // Reap the child without blocking so the PID slot is freed when the
        // shell exits. We don't care about the exit status; the read loop will
        // surface EOF/ENXIO and call onExit.
        DispatchQueue.global(qos: .background).async { [pid] in
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }

        startReader()
        return true
    }

    private func startReader() {
        let fd = masterFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                self.onOutput?(Data(buf.prefix(Int(n))))
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                self.onExit?()
                self.readSource?.cancel()
                self.readSource = nil
            }
        }
        source.resume()
        readSource = source
    }

    func write(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var remaining = raw.count
            var p = base
            while remaining > 0 {
                let n = Darwin.write(masterFD, p, remaining)
                if n <= 0 {
                    if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                    return
                }
                p = p.advanced(by: n)
                remaining -= n
            }
        }
    }

    func resize(rows: Int, cols: Int) {
        guard masterFD >= 0 else { return }
        var ws = winsize(ws_row: UInt16(max(rows, 1)),
                         ws_col: UInt16(max(cols, 1)),
                         ws_xpixel: 0,
                         ws_ypixel: 0)
        _ = ioctl(masterFD, _TIOCSWINSZ, &ws)
    }

    func terminate() {
        if pid > 0 {
            kill(pid, SIGHUP)
            pid = -1
        }
        readSource?.cancel()
        readSource = nil
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    deinit { terminate() }
}

// MARK: - Terminal buffer: ANSI parser + NSTextStorage
//
// Stream-oriented model. Output bytes are parsed into the storage with a
// movable cursor. CR rewinds the cursor to column 0; subsequent writes
// overwrite the existing characters on that row, which is what shells expect
// when redrawing a prompt. Escape sequences we don't understand are consumed
// silently so they don't show up as garbage.

final class TerminalBuffer {
    let storage = NSTextStorage()

    private let font: NSFont
    private let defaultColor: NSColor
    private let defaultAttrs: [NSAttributedString.Key: Any]
    private var currentAttrs: [NSAttributedString.Key: Any]

    /// Insertion point in `storage`. Always 0...storage.length. Exposed so
    /// the view can place a blinking cursor at the right pixel position.
    private(set) var cursor: Int = 0

    private enum ParserState { case ground, esc, csi, oscOrPrivate }
    private var state: ParserState = .ground
    private var csiParams: [UInt8] = []

    /// UTF-8 staging for multi-byte glyphs. Bytes accumulate until they form a
    /// valid scalar, then flush as a single character.
    private var pendingBytes: [UInt8] = []

    var onChange: (() -> Void)?

    init(font: NSFont, defaultColor: NSColor) {
        self.font = font
        self.defaultColor = defaultColor
        self.defaultAttrs = [
            .font: font,
            .foregroundColor: defaultColor,
        ]
        self.currentAttrs = defaultAttrs
    }

    func feed(_ data: Data) {
        for byte in data {
            switch state {
            case .ground:
                handleGround(byte)
            case .esc:
                handleEsc(byte)
            case .csi:
                handleCSI(byte)
            case .oscOrPrivate:
                // OSC ends on BEL or ST (ESC \). Discard everything until then.
                if byte == 0x07 { state = .ground }
                else if byte == 0x1b { state = .esc /* will fold ST */ }
            }
        }
        flushPending()
        onChange?()
    }

    // MARK: state handlers

    private func handleGround(_ byte: UInt8) {
        switch byte {
        case 0x1b:                // ESC
            flushPending()
            state = .esc
        case 0x07:                // BEL
            break
        case 0x08:                // BS
            flushPending()
            backspace()
        case 0x09:                // TAB
            flushPending()
            tab()
        case 0x0a:                // LF
            flushPending()
            lineFeed()
        case 0x0d:                // CR
            flushPending()
            carriageReturn()
        default:
            pendingBytes.append(byte)
            // Try to flush eagerly so the on-screen text stays current within
            // a single feed() call. If the bytes form a valid UTF-8 sequence,
            // emit; otherwise wait for more bytes.
            if let str = String(bytes: pendingBytes, encoding: .utf8) {
                writeString(str)
                pendingBytes.removeAll(keepingCapacity: true)
            } else if pendingBytes.count > 6 {
                // Not a valid UTF-8 sequence even with 6 bytes — drop, recover.
                pendingBytes.removeAll(keepingCapacity: true)
            }
        }
    }

    private func handleEsc(_ byte: UInt8) {
        switch byte {
        case 0x5b /* [ */:
            state = .csi
            csiParams.removeAll(keepingCapacity: true)
        case 0x5d /* ] */, 0x50 /* P */, 0x5e /* ^ */, 0x5f /* _ */:
            state = .oscOrPrivate
        default:
            // Two-character escape like ESC c (reset) — skip; we've already
            // consumed the second byte by entering this branch.
            state = .ground
        }
    }

    private func handleCSI(_ byte: UInt8) {
        if (0x30...0x3f).contains(byte) {
            csiParams.append(byte)
        } else if (0x40...0x7e).contains(byte) {
            executeCSI(final: byte)
            state = .ground
        } else {
            // Unexpected; recover.
            state = .ground
        }
    }

    private func flushPending() {
        guard !pendingBytes.isEmpty else { return }
        if let str = String(bytes: pendingBytes, encoding: .utf8) {
            writeString(str)
        }
        pendingBytes.removeAll(keepingCapacity: true)
    }

    // MARK: editing primitives

    private func writeString(_ s: String) {
        let attr = NSAttributedString(string: s, attributes: currentAttrs)
        let nsLen = (s as NSString).length
        if cursor < storage.length {
            // Overwrite mode — but never cross a newline. Replace up to the
            // next \n, then append the rest.
            let storageStr = storage.string as NSString
            var end = cursor
            var written = 0
            while end < storage.length, written < nsLen,
                  storageStr.character(at: end) != 0x0a {
                end += 1
                written += 1
            }
            let overwriteRange = NSRange(location: cursor, length: end - cursor)
            if overwriteRange.length == nsLen {
                storage.replaceCharacters(in: overwriteRange, with: attr)
                cursor = end
            } else {
                let head = attr.attributedSubstring(from: NSRange(location: 0, length: written))
                storage.replaceCharacters(in: overwriteRange, with: head)
                cursor = end
                let tail = attr.attributedSubstring(from: NSRange(location: written, length: nsLen - written))
                storage.insert(tail, at: cursor)
                cursor += tail.length
            }
        } else {
            storage.append(attr)
            cursor = storage.length
        }
    }

    private func backspace() {
        guard cursor > 0 else { return }
        let prev = (storage.string as NSString).character(at: cursor - 1)
        if prev != 0x0a { cursor -= 1 }
    }

    private func tab() {
        let col = currentColumn()
        let next = ((col / 8) + 1) * 8
        writeString(String(repeating: " ", count: next - col))
    }

    private func lineFeed() {
        // Treat as cursor-down + carriage-return blend: jump to end of buffer
        // and append a newline. For an MVP shell this matches CR+LF semantics
        // shells emit; rare bare-LF cases fall through harmlessly.
        if cursor < storage.length {
            let s = storage.string as NSString
            var i = cursor
            while i < s.length, s.character(at: i) != 0x0a { i += 1 }
            cursor = i
        }
        let nl = NSAttributedString(string: "\n", attributes: defaultAttrs)
        if cursor == storage.length {
            storage.append(nl)
            cursor = storage.length
        } else {
            // We're on an existing newline character. Move past it.
            cursor += 1
        }
    }

    private func carriageReturn() {
        let s = storage.string as NSString
        var i = cursor - 1
        while i >= 0 {
            if s.character(at: i) == 0x0a {
                cursor = i + 1
                return
            }
            i -= 1
        }
        cursor = 0
    }

    private func currentColumn() -> Int {
        let s = storage.string as NSString
        var col = 0
        var i = cursor - 1
        while i >= 0 {
            if s.character(at: i) == 0x0a { return col }
            col += 1
            i -= 1
        }
        return col
    }

    // MARK: CSI dispatch

    private func executeCSI(final: UInt8) {
        let raw = String(bytes: csiParams, encoding: .ascii) ?? ""
        // Skip private-mode prefix (e.g. "?25h" hides cursor) — we don't act
        // on them but also don't want them tripping the param parser.
        let body: Substring = raw.first == "?" ? raw.dropFirst() : Substring(raw)
        let params = body.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }

        switch final {
        case 0x6d /* m */:
            applySGR(params: params.isEmpty ? [0] : params)
        case 0x4b /* K */:
            // Erase in line: 0=cursor→end, 1=start→cursor, 2=entire line.
            let p = params.first ?? 0
            switch p {
            case 0: eraseToEndOfLine()
            case 1: eraseToStartOfLine()
            case 2: eraseEntireLine()
            default: break
            }
        case 0x4a /* J */:
            // Erase in display: 2=full screen.
            if (params.first ?? 0) == 2 {
                storage.deleteCharacters(in: NSRange(location: 0, length: storage.length))
                cursor = 0
            }
        default:
            // C/D/A/B (cursor moves), H (cursor position), etc. — ignored for
            // MVP. Most are no-ops in the flat insertion-point model anyway.
            break
        }
    }

    private func eraseToEndOfLine() {
        let s = storage.string as NSString
        var end = cursor
        while end < s.length, s.character(at: end) != 0x0a { end += 1 }
        if end > cursor {
            storage.deleteCharacters(in: NSRange(location: cursor, length: end - cursor))
        }
    }

    private func eraseToStartOfLine() {
        let s = storage.string as NSString
        var start = cursor
        while start > 0, s.character(at: start - 1) != 0x0a { start -= 1 }
        if cursor > start {
            // Replace with spaces to keep the cursor column. Shells don't
            // really rely on this, but it's the spec'd behavior.
            let pad = NSAttributedString(string: String(repeating: " ", count: cursor - start),
                                         attributes: defaultAttrs)
            storage.replaceCharacters(in: NSRange(location: start, length: cursor - start), with: pad)
        }
    }

    private func eraseEntireLine() {
        let s = storage.string as NSString
        var start = cursor
        while start > 0, s.character(at: start - 1) != 0x0a { start -= 1 }
        var end = cursor
        while end < s.length, s.character(at: end) != 0x0a { end += 1 }
        if end > start {
            storage.deleteCharacters(in: NSRange(location: start, length: end - start))
            cursor = start
        }
    }

    private func applySGR(params: [Int]) {
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                currentAttrs = defaultAttrs
            case 1:
                // Bold — leave font alone for MVP; bright color via 90+ already covers most cases.
                break
            case 30...37:
                currentAttrs[.foregroundColor] = ansi8Color(p - 30, bright: false)
            case 39:
                currentAttrs[.foregroundColor] = defaultColor
            case 90...97:
                currentAttrs[.foregroundColor] = ansi8Color(p - 90, bright: true)
            case 38:
                // Extended color: 38;5;n (256) or 38;2;r;g;b (truecolor).
                if i + 1 < params.count, params[i + 1] == 5, i + 2 < params.count {
                    currentAttrs[.foregroundColor] = xterm256Color(params[i + 2])
                    i += 2
                } else if i + 1 < params.count, params[i + 1] == 2, i + 4 < params.count {
                    let r = CGFloat(params[i + 2]) / 255.0
                    let g = CGFloat(params[i + 3]) / 255.0
                    let b = CGFloat(params[i + 4]) / 255.0
                    currentAttrs[.foregroundColor] = NSColor(red: r, green: g, blue: b, alpha: 1)
                    i += 4
                }
            default:
                break
            }
            i += 1
        }
    }

    private func ansi8Color(_ index: Int, bright: Bool) -> NSColor {
        let normal: [NSColor] = [
            NSColor(srgbRed: 0.00, green: 0.00, blue: 0.00, alpha: 1),  // black
            NSColor(srgbRed: 0.80, green: 0.20, blue: 0.20, alpha: 1),  // red
            NSColor(srgbRed: 0.30, green: 0.75, blue: 0.30, alpha: 1),  // green
            NSColor(srgbRed: 0.85, green: 0.75, blue: 0.20, alpha: 1),  // yellow
            NSColor(srgbRed: 0.30, green: 0.55, blue: 0.85, alpha: 1),  // blue
            NSColor(srgbRed: 0.78, green: 0.40, blue: 0.78, alpha: 1),  // magenta
            NSColor(srgbRed: 0.30, green: 0.78, blue: 0.78, alpha: 1),  // cyan
            NSColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1),  // white
        ]
        let brightT: [NSColor] = [
            NSColor(srgbRed: 0.50, green: 0.50, blue: 0.50, alpha: 1),
            NSColor(srgbRed: 1.00, green: 0.40, blue: 0.40, alpha: 1),
            NSColor(srgbRed: 0.45, green: 0.95, blue: 0.45, alpha: 1),
            NSColor(srgbRed: 1.00, green: 0.95, blue: 0.40, alpha: 1),
            NSColor(srgbRed: 0.50, green: 0.75, blue: 1.00, alpha: 1),
            NSColor(srgbRed: 1.00, green: 0.55, blue: 1.00, alpha: 1),
            NSColor(srgbRed: 0.50, green: 1.00, blue: 1.00, alpha: 1),
            NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        ]
        let table = bright ? brightT : normal
        guard index >= 0, index < table.count else { return defaultColor }
        return table[index]
    }

    private func xterm256Color(_ n: Int) -> NSColor {
        // 0–15: standard 16 colors
        if n < 8  { return ansi8Color(n,     bright: false) }
        if n < 16 { return ansi8Color(n - 8, bright: true)  }
        // 16–231: 6×6×6 cube
        if n < 232 {
            let v = n - 16
            let r = (v / 36) % 6
            let g = (v / 6)  % 6
            let b = v        % 6
            let levels: [CGFloat] = [0.0, 0.37, 0.53, 0.69, 0.84, 1.00]
            return NSColor(srgbRed: levels[r], green: levels[g], blue: levels[b], alpha: 1)
        }
        // 232–255: 24-step grayscale ramp
        let t = CGFloat(n - 232) / 23.0
        return NSColor(srgbRed: t, green: t, blue: t, alpha: 1)
    }
}

// MARK: - Terminal text view (input handling)

final class TerminalTextView: NSTextView {
    /// Bytes to send to the PTY when the user types or pastes.
    var onInput: ((Data) -> Void)?
    /// Fires when the user clicks into the terminal — the pane uses this to
    /// mark itself as the active pane in the Editor coordinator.
    var onBecomeFirstResponder: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onBecomeFirstResponder?() }
        return result
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd shortcuts: copy / paste / select-all flow through the text view's
        // selection so users can yank output into other apps. Paste sends the
        // pasteboard content into the PTY so shells see it as typed input.
        if mods == .command, let chars = event.charactersIgnoringModifiers {
            switch chars.lowercased() {
            case "c": self.copy(self); return
            case "v":
                if let s = NSPasteboard.general.string(forType: .string) {
                    onInput?(Data(s.utf8))
                }
                return
            case "a": self.selectAll(self); return
            default: break
            }
        }

        // Arrow keys, home/end, fwd-delete → escape sequences the shell expects.
        if let data = translateSpecialKey(event) {
            onInput?(data)
            return
        }

        // Ctrl+letter → C0 control byte (Ctrl+C → 0x03, Ctrl+D → 0x04, etc.).
        if mods == .control, let chars = event.charactersIgnoringModifiers,
           let scalar = chars.unicodeScalars.first {
            let v = scalar.value
            if v >= 0x40, v <= 0x5f {
                onInput?(Data([UInt8(v - 0x40)])); return
            } else if v >= 0x61, v <= 0x7a {
                onInput?(Data([UInt8(v - 0x60)])); return
            }
        }

        // Plain text and recognized control chars (Return → \r, Tab → \t,
        // Backspace → \u{7f}, Esc → \u{1b}) come through `event.characters`
        // already in the right encoding for a Unix shell.
        if let chars = event.characters, !chars.isEmpty {
            onInput?(Data(chars.utf8))
        }
    }

    private func translateSpecialKey(_ event: NSEvent) -> Data? {
        switch event.keyCode {
        case 126: return Data([0x1b, 0x5b, 0x41]) // up
        case 125: return Data([0x1b, 0x5b, 0x42]) // down
        case 124: return Data([0x1b, 0x5b, 0x43]) // right
        case 123: return Data([0x1b, 0x5b, 0x44]) // left
        case 117: return Data([0x1b, 0x5b, 0x33, 0x7e]) // forward delete
        case 115: return Data([0x1b, 0x5b, 0x48]) // home
        case 119: return Data([0x1b, 0x5b, 0x46]) // end
        default:  return nil
        }
    }
}

// MARK: - Cursor overlay
//
// A 1-cell rectangle drawn over the text view at the buffer's cursor index.
// Hit testing is disabled so it never absorbs clicks meant for the text view.

private final class CursorOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { return nil }
}

// MARK: - Terminal view: wires session, buffer, text view, scroll view

final class TerminalView: NSView {
    let session: TerminalSession
    let buffer: TerminalBuffer
    private let scrollView: NSScrollView
    /// Exposed so the owning Pane can route focus events back to the Editor
    /// coordinator (mark this pane as focused on click).
    let textView: TerminalTextView
    private let cellFont: NSFont
    private var lastReportedRows: Int = 0
    private var lastReportedCols: Int = 0
    private let cursorView = CursorOverlayView()
    private var cursorTimer: Timer?
    private var cursorOn: Bool = true
    private let cellWidth: CGFloat
    private let cellHeight: CGFloat

    init(session: TerminalSession, buffer: TerminalBuffer, font: NSFont) {
        self.session = session
        self.buffer = buffer
        self.cellFont = font
        let measured = ("M" as NSString).size(withAttributes: [.font: font])
        self.cellWidth = max(measured.width, 1)
        self.cellHeight = max(font.boundingRectForFont.height, 1)

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.background
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller = MinimalScroller()

        let initial = NSRect(origin: .zero, size: NSSize(width: 600, height: 400))
        textView = TerminalTextView(frame: initial)
        textView.minSize = NSSize(width: 0, height: initial.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.font = font
        textView.backgroundColor = Theme.background
        textView.textColor = Theme.foreground
        textView.insertionPointColor = Theme.cursor
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = false
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false

        // Bind the buffer's storage so the parser writes show up automatically.
        textView.layoutManager?.replaceTextStorage(buffer.storage)
        scrollView.documentView = textView

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        textView.onInput = { [weak self] data in
            self?.session.write(data)
        }

        // Scroll to bottom whenever the parser advances the buffer; gated by
        // a flag so the user can scroll up to read history without being
        // yanked back on every output chunk.
        buffer.onChange = { [weak self] in
            self?.handleBufferChanged()
        }

        // Cursor overlay — a 1-cell block painted at the buffer cursor's
        // pixel position. The text view's text container is its own layout
        // root, so we attach the overlay there and trust scrolling to move it
        // along with the rest of the document content.
        cursorView.wantsLayer = true
        cursorView.layer?.backgroundColor = Theme.foreground.cgColor
        cursorView.frame = NSRect(x: 0, y: 0, width: cellWidth, height: cellHeight)
        textView.addSubview(cursorView)
        startCursorBlink()
        updateCursorPosition()
    }

    deinit {
        cursorTimer?.invalidate()
    }

    private func startCursorBlink() {
        // 530ms matches Apple's default insertion-point blink rate. We toggle
        // the overlay's hidden flag rather than animating opacity so the
        // cursor snaps cleanly without sub-pixel flicker.
        let timer = Timer(timeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.cursorOn.toggle()
            self.cursorView.isHidden = !self.cursorOn
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    /// Place the overlay at the buffer cursor's pixel position. Called after
    /// every parser update so the block tracks input echo, BS-space-BS erase
    /// sequences, and prompt redraws. Resets the blink phase so the cursor is
    /// visible right after activity instead of mid-off-cycle.
    private func updateCursorPosition() {
        guard let lm = textView.layoutManager,
              let container = textView.textContainer else { return }
        lm.ensureLayout(for: container)

        let length = buffer.storage.length
        let idx = min(buffer.cursor, length)
        let inset = textView.textContainerInset

        let rect: NSRect
        if length == 0 {
            // Empty buffer — the cursor is at the very top-left of the
            // content area.
            rect = NSRect(x: 0, y: 0, width: cellWidth, height: cellHeight)
        } else if idx < length {
            let glyphIdx = lm.glyphIndexForCharacter(at: idx)
            let charRect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1),
                                           in: container)
            rect = NSRect(x: charRect.minX, y: charRect.minY,
                          width: cellWidth, height: charRect.height)
        } else {
            // Cursor sits at storage.length (just past the last character).
            // If that last char is a newline, drop down to column 0 of the
            // next row; otherwise advance one cell to the right of it.
            let lastIdx = length - 1
            let lastGlyph = lm.glyphIndexForCharacter(at: lastIdx)
            let lastRect = lm.boundingRect(forGlyphRange: NSRange(location: lastGlyph, length: 1),
                                           in: container)
            let lastChar = (buffer.storage.string as NSString).character(at: lastIdx)
            if lastChar == 0x0a {
                rect = NSRect(x: 0, y: lastRect.maxY,
                              width: cellWidth, height: lastRect.height)
            } else {
                rect = NSRect(x: lastRect.maxX, y: lastRect.minY,
                              width: cellWidth, height: lastRect.height)
            }
        }

        let target = rect.offsetBy(dx: inset.width, dy: inset.height)
        // Skip implicit animation so the cursor snaps to its new spot — a
        // smoothly-tweened cursor reads as laggy in a terminal.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorView.frame = target
        CATransaction.commit()

        cursorOn = true
        cursorView.isHidden = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Take focus when this view becomes active so typing goes straight to
    /// the shell. Called by the pane after swapping content.
    func focusInput() {
        window?.makeFirstResponder(textView)
    }

    private func handleBufferChanged() {
        // If the user is parked near the bottom, follow new output. If they've
        // scrolled up, leave them alone — a future "scroll lock" indicator
        // could make this discoverable.
        let clip = scrollView.contentView
        let docMax = clip.documentRect.maxY
        let viewportMax = clip.bounds.maxY
        if docMax - viewportMax < cellFont.boundingRectForFont.height * 2 {
            textView.scrollRangeToVisible(NSRange(location: buffer.storage.length, length: 0))
        }
        updateCursorPosition()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        sendResizeToPTY()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sendResizeToPTY()
        if window != nil { focusInput() }
    }

    private func sendResizeToPTY() {
        let charSize = ("M" as NSString).size(withAttributes: [.font: cellFont])
        let cw = max(charSize.width, 1)
        let ch = max(cellFont.boundingRectForFont.height, 1)
        let inset = textView.textContainerInset
        let usableW = max(bounds.width - inset.width * 2, cw)
        let usableH = max(bounds.height - inset.height * 2, ch)
        let cols = max(1, Int(usableW / cw))
        let rows = max(1, Int(usableH / ch))
        if rows == lastReportedRows, cols == lastReportedCols { return }
        lastReportedRows = rows
        lastReportedCols = cols
        session.resize(rows: rows, cols: cols)
    }
}

// MARK: - Terminal state (lives on a DocumentTab when kind == .terminal)

final class TerminalState {
    let session: TerminalSession
    let buffer: TerminalBuffer
    let view: TerminalView
    /// Notifies the owning pane so it can close the tab automatically when
    /// the shell exits.
    var onShellExit: (() -> Void)?

    init(font: NSFont) {
        let session = TerminalSession()
        let buffer = TerminalBuffer(font: font, defaultColor: Theme.foreground)
        let view = TerminalView(session: session, buffer: buffer, font: font)
        self.session = session
        self.buffer = buffer
        self.view = view

        session.onOutput = { [weak buffer] data in
            buffer?.feed(data)
        }
        session.onExit = { [weak self] in
            self?.onShellExit?()
        }
    }

    /// Spawn the shell process. Should be called once after construction. The
    /// PTY size is refined as soon as the view is laid out in a window.
    func start() {
        session.start(rows: 24, cols: 80)
    }
}
