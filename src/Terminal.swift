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

        // Make sure the child sees a TERM the rest of the world recognizes.
        // Without this most shells fall back to "dumb" or guess based on
        // whatever's in the parent's environment (which, for a Finder-launched
        // .app, is usually nothing). xterm-256color is the safe lingua franca.
        // Modifying the parent's env is fine — Kantan itself doesn't read
        // these, and exec'd children inherit it via execv.
        setenv("TERM", "xterm-256color", 1)
        setenv("COLORTERM", "truecolor", 1)
        setenv("TERM_PROGRAM", "Kantan", 1)

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

// MARK: - Cell + grid
//
// A cell is one screen position with its character and SGR-derived attributes.
// A grid is a 2D array of cells with a cursor, sized to the terminal's
// rows × cols. Two grids exist per terminal: a main grid that also feeds
// scrollback, and an alternate grid that full-screen TUIs (vim, less, Claude
// Code) swap to via DEC mode 1049.

struct TermCell {
    var char: Character = " "
    var fg: NSColor
    var bg: NSColor
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var inverse: Bool = false
}

final class TermGrid {
    private(set) var rows: Int
    private(set) var cols: Int
    var cells: [[TermCell]]
    var cursorRow: Int = 0
    var cursorCol: Int = 0

    init(rows: Int, cols: Int, blank: TermCell) {
        self.rows = rows
        self.cols = cols
        self.cells = (0..<rows).map { _ in Array(repeating: blank, count: cols) }
    }

    /// Resize the grid in place, preserving as many cells as fit. Cursor is
    /// clamped to the new bounds.
    func resize(rows newRows: Int, cols newCols: Int, blank: TermCell) {
        guard newRows != rows || newCols != cols else { return }
        if newCols != cols {
            for r in 0..<min(rows, newRows == 0 ? rows : newRows) {
                if newCols > cols {
                    cells[r].append(contentsOf: Array(repeating: blank, count: newCols - cols))
                } else {
                    cells[r].removeLast(cols - newCols)
                }
            }
        }
        if newRows > rows {
            for _ in rows..<newRows {
                cells.append(Array(repeating: blank, count: newCols))
            }
        } else if newRows < rows {
            cells.removeLast(rows - newRows)
        }
        rows = newRows
        cols = newCols
        cursorRow = min(cursorRow, max(0, rows - 1))
        cursorCol = min(cursorCol, max(0, cols - 1))
    }
}

// MARK: - Terminal emulator
//
// xterm-flavored VT100/ANSI emulator. Output bytes drive a state-machine
// parser that mutates the active grid. The grid is rebuilt into the
// NSTextStorage on each feed() so the view layer just renders an attributed
// string and doesn't have to know about cells.
//
// Supported (enough for vim/less/htop and Claude Code):
//   - Cursor positioning: H/f, A/B/C/D/E/F, G, d
//   - Erase: J (0/1/2), K (0/1/2)
//   - Insert/delete: @, P, X, L, M
//   - Scroll: S, T, scrolling region (r), index/reverse-index/next-line
//   - Save/restore cursor: ESC 7/8, CSI s/u
//   - SGR: bold/italic/underline/inverse, 8/16/256/truecolor fg+bg
//   - Private modes: ?25 (cursor visible), ?1049/?47/?1047 (alt screen),
//     ?2004 (bracketed paste)
//   - Device status: DSR cursor position report (n)
//   - Scrollback for the main grid (capped at scrollbackLimit)
// Not supported: scrolling regions across alt screen edge cases,
// double-width chars, true reflow on resize, mouse modes, sixel.

final class TerminalEmulator {
    let storage = NSTextStorage()
    private(set) var rows: Int
    private(set) var cols: Int

    private let cellFont: NSFont
    private let defaultCell: TermCell
    private var attrs: TermCell

    private let mainGrid: TermGrid
    private let altGrid: TermGrid
    private(set) var useAlternate: Bool = false
    private var grid: TermGrid { useAlternate ? altGrid : mainGrid }

    /// Lines that have scrolled off the top of the main grid. Capped to
    /// `scrollbackLimit`; oldest lines are dropped when the cap is hit. Alt
    /// screen never contributes to scrollback (per spec).
    private var scrollback: [[TermCell]] = []
    private let scrollbackLimit: Int

    private var savedRow: Int = 0
    private var savedCol: Int = 0
    private var savedAttrs: TermCell?
    private var savedAltRow: Int = 0
    private var savedAltCol: Int = 0
    private var savedAltAttrs: TermCell?

    /// Inclusive scrolling region rows (0-indexed). Defaults to full screen.
    private var scrollTop: Int
    private var scrollBottom: Int

    /// "Pending wrap" flag — when the cursor has just written into the last
    /// column, the next character triggers the wrap. xterm calls this DECAWM
    /// last-column behavior; without it backspace in column 79 is wrong.
    private var pendingWrap: Bool = false

    private(set) var cursorVisible: Bool = true
    private(set) var bracketedPasteEnabled: Bool = false

    private enum State { case ground, esc, csi, osc, designator }
    private var state: State = .ground
    private var csiParams: [UInt8] = []
    private var pendingBytes: [UInt8] = []

    var onChange: (() -> Void)?
    var onCursorVisibilityChanged: ((Bool) -> Void)?
    /// Replies the emulator wants to send back to the shell — DSR responses,
    /// for example. The view layer wires this to TerminalSession.write.
    var onWriteToPTY: ((Data) -> Void)?

    init(rows: Int, cols: Int, font: NSFont,
         defaultFG: NSColor, defaultBG: NSColor,
         scrollbackLimit: Int = 1000) {
        self.rows = rows
        self.cols = cols
        self.cellFont = font
        self.defaultCell = TermCell(char: " ", fg: defaultFG, bg: defaultBG)
        self.attrs = self.defaultCell
        self.mainGrid = TermGrid(rows: rows, cols: cols, blank: self.defaultCell)
        self.altGrid = TermGrid(rows: rows, cols: cols, blank: self.defaultCell)
        self.scrollbackLimit = scrollbackLimit
        self.scrollTop = 0
        self.scrollBottom = rows - 1
        rebuildStorage()
    }

    // MARK: - Public API

    func feed(_ data: Data) {
        for byte in data {
            switch state {
            case .ground:     handleGround(byte)
            case .esc:        handleEsc(byte)
            case .csi:        handleCSI(byte)
            case .osc:        handleOSC(byte)
            case .designator: state = .ground   // skip one char (G0/G1 designator)
            }
        }
        // Don't flushPending here — partial UTF-8 sequences legitimately
        // straddle PTY read boundaries, and dropping them would corrupt
        // multi-byte glyphs near a chunk seam.
        rebuildStorage()
        onChange?()
    }

    func resize(rows newRows: Int, cols newCols: Int) {
        guard newRows > 0, newCols > 0 else { return }
        guard newRows != rows || newCols != cols else { return }
        mainGrid.resize(rows: newRows, cols: newCols, blank: defaultCell)
        altGrid.resize(rows: newRows, cols: newCols, blank: defaultCell)
        rows = newRows
        cols = newCols
        scrollTop = 0
        scrollBottom = newRows - 1
        pendingWrap = false
        rebuildStorage()
        onChange?()
    }

    /// Flat index into `storage` where the cursor cell lives. Each row
    /// occupies `cols` chars + 1 newline, prefixed by `scrollback.count` lines
    /// when the main grid is active.
    var cursorStorageIndex: Int {
        let scrollbackCount = useAlternate ? 0 : scrollback.count
        let row = scrollbackCount + grid.cursorRow
        // Clamp to last column so the overlay sits over a real cell rather
        // than the row-terminating newline when "pending wrap" is active.
        let col = min(grid.cursorCol, cols - 1)
        return row * (cols + 1) + col
    }

    // MARK: - Parser

    private func handleGround(_ byte: UInt8) {
        switch byte {
        case 0x1b: flushPending(); state = .esc
        case 0x07: break                                   // BEL
        case 0x08: flushPending(); cursorBack()            // BS
        case 0x09: flushPending(); tab()                   // HT
        case 0x0a, 0x0b, 0x0c:                             // LF / VT / FF
            flushPending(); lineFeed()
        case 0x0d: flushPending(); carriageReturn()        // CR
        case 0x7f: break                                   // DEL — output side ignores
        default:
            pendingBytes.append(byte)
            if let s = String(bytes: pendingBytes, encoding: .utf8) {
                writeText(s)
                pendingBytes.removeAll(keepingCapacity: true)
            } else if pendingBytes.count > 6 {
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
            state = .osc
        case 0x37 /* 7 */: saveCursor();    state = .ground
        case 0x38 /* 8 */: restoreCursor(); state = .ground
        case 0x44 /* D */: index();         state = .ground
        case 0x45 /* E */: nextLine();      state = .ground
        case 0x4d /* M */: reverseIndex();  state = .ground
        case 0x63 /* c */: hardReset();     state = .ground
        case 0x28, 0x29, 0x2a, 0x2b /* ( ) * + */:
            // G0/G1/G2/G3 character set designators — eat the next byte and
            // ignore. We always render UTF-8.
            state = .designator
        default:
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
            state = .ground
        }
    }

    private func handleOSC(_ byte: UInt8) {
        // OSC sequences (window title, hyperlinks, etc.) are discarded but
        // we have to track the terminator so the data inside doesn't leak
        // back into the ground state and corrupt rendering.
        if byte == 0x07 {              // BEL
            state = .ground
        } else if byte == 0x1b {       // ESC \  (ST) — re-enter esc state to
            state = .esc               //  consume the trailing backslash.
        }
    }

    private func flushPending() {
        if !pendingBytes.isEmpty,
           let s = String(bytes: pendingBytes, encoding: .utf8) {
            writeText(s)
        }
        pendingBytes.removeAll(keepingCapacity: true)
    }

    // MARK: - Cursor + writing primitives

    private func writeText(_ s: String) {
        for ch in s { writeCell(ch) }
    }

    private func writeCell(_ ch: Character) {
        if pendingWrap {
            grid.cursorCol = 0
            grid.cursorRow += 1
            if grid.cursorRow > scrollBottom {
                scrollGridUp()
                grid.cursorRow = scrollBottom
            }
            pendingWrap = false
        }
        var cell = attrs
        cell.char = ch
        if grid.cursorRow >= 0, grid.cursorRow < rows,
           grid.cursorCol >= 0, grid.cursorCol < cols {
            grid.cells[grid.cursorRow][grid.cursorCol] = cell
        }
        if grid.cursorCol == cols - 1 {
            // Stay on the last column; the next character flips pendingWrap.
            pendingWrap = true
        } else {
            grid.cursorCol += 1
        }
    }

    private func cursorBack() {
        if pendingWrap { pendingWrap = false; return }
        if grid.cursorCol > 0 { grid.cursorCol -= 1 }
    }

    private func tab() {
        let next = ((grid.cursorCol / 8) + 1) * 8
        grid.cursorCol = min(next, cols - 1)
        pendingWrap = false
    }

    private func lineFeed() {
        pendingWrap = false
        if grid.cursorRow == scrollBottom {
            scrollGridUp()
        } else {
            grid.cursorRow = min(rows - 1, grid.cursorRow + 1)
        }
    }

    private func carriageReturn() {
        grid.cursorCol = 0
        pendingWrap = false
    }

    private func index()        { lineFeed() }                 // ESC D
    private func nextLine()     { lineFeed(); carriageReturn() } // ESC E

    private func reverseIndex() {                              // ESC M
        pendingWrap = false
        if grid.cursorRow == scrollTop {
            scrollGridDown()
        } else if grid.cursorRow > 0 {
            grid.cursorRow -= 1
        }
    }

    private func hardReset() {                                 // ESC c
        attrs = defaultCell
        grid.cursorRow = 0
        grid.cursorCol = 0
        scrollTop = 0
        scrollBottom = rows - 1
        cursorVisible = true
        bracketedPasteEnabled = false
        pendingWrap = false
        for r in 0..<rows {
            for c in 0..<cols { grid.cells[r][c] = defaultCell }
        }
        onCursorVisibilityChanged?(cursorVisible)
    }

    private func saveCursor() {                                // ESC 7 / CSI s
        if useAlternate {
            savedAltRow = grid.cursorRow
            savedAltCol = grid.cursorCol
            savedAltAttrs = attrs
        } else {
            savedRow = grid.cursorRow
            savedCol = grid.cursorCol
            savedAttrs = attrs
        }
    }

    private func restoreCursor() {                             // ESC 8 / CSI u
        let r: Int, c: Int
        let a: TermCell?
        if useAlternate {
            r = savedAltRow; c = savedAltCol; a = savedAltAttrs
        } else {
            r = savedRow; c = savedCol; a = savedAttrs
        }
        grid.cursorRow = min(r, rows - 1)
        grid.cursorCol = min(c, cols - 1)
        if let a = a { attrs = a }
        pendingWrap = false
    }

    // MARK: - Scrolling

    private func scrollGridUp() {
        // Only the topmost line of a full-screen scroll feeds scrollback,
        // and only when the main grid is active and the scroll region spans
        // the whole screen. Scroll regions used inside an editor (e.g. vim
        // status line) shouldn't bleed into history.
        let regionTop = scrollTop
        let regionBottom = scrollBottom
        if !useAlternate, regionTop == 0, regionBottom == rows - 1 {
            scrollback.append(grid.cells[regionTop])
            if scrollback.count > scrollbackLimit {
                scrollback.removeFirst(scrollback.count - scrollbackLimit)
            }
        }
        for r in regionTop..<regionBottom {
            grid.cells[r] = grid.cells[r + 1]
        }
        grid.cells[regionBottom] = Array(repeating: defaultCell, count: cols)
    }

    private func scrollGridDown() {
        for r in stride(from: scrollBottom, to: scrollTop, by: -1) {
            grid.cells[r] = grid.cells[r - 1]
        }
        grid.cells[scrollTop] = Array(repeating: defaultCell, count: cols)
    }

    // MARK: - CSI dispatch

    private func executeCSI(final: UInt8) {
        let raw = String(bytes: csiParams, encoding: .ascii) ?? ""
        let isPrivate = raw.first == "?"
        let body: Substring = isPrivate ? raw.dropFirst() : Substring(raw)
        let parts = body.split(separator: ";", omittingEmptySubsequences: false)
        let params: [Int] = parts.map { Int($0) ?? 0 }
        let firstParam = params.first ?? 0

        switch (final, isPrivate) {
        case (0x6d, false):                       // SGR
            applySGR(params.isEmpty ? [0] : params)

        case (0x48, false), (0x66, false):        // CUP / HVP
            let r = max(1, params.count > 0 && params[0] != 0 ? params[0] : 1) - 1
            let c = max(1, params.count > 1 && params[1] != 0 ? params[1] : 1) - 1
            grid.cursorRow = min(r, rows - 1)
            grid.cursorCol = min(c, cols - 1)
            pendingWrap = false

        case (0x41, false):                       // CUU
            let n = max(1, firstParam)
            grid.cursorRow = max(0, grid.cursorRow - n)
            pendingWrap = false
        case (0x42, false):                       // CUD
            let n = max(1, firstParam)
            grid.cursorRow = min(rows - 1, grid.cursorRow + n)
            pendingWrap = false
        case (0x43, false):                       // CUF
            let n = max(1, firstParam)
            grid.cursorCol = min(cols - 1, grid.cursorCol + n)
            pendingWrap = false
        case (0x44, false):                       // CUB
            let n = max(1, firstParam)
            grid.cursorCol = max(0, grid.cursorCol - n)
            pendingWrap = false
        case (0x45, false):                       // CNL
            grid.cursorRow = min(rows - 1, grid.cursorRow + max(1, firstParam))
            grid.cursorCol = 0
            pendingWrap = false
        case (0x46, false):                       // CPL
            grid.cursorRow = max(0, grid.cursorRow - max(1, firstParam))
            grid.cursorCol = 0
            pendingWrap = false
        case (0x47, false):                       // CHA
            let c = max(1, firstParam == 0 ? 1 : firstParam) - 1
            grid.cursorCol = min(c, cols - 1)
            pendingWrap = false
        case (0x64, false):                       // VPA
            let r = max(1, firstParam == 0 ? 1 : firstParam) - 1
            grid.cursorRow = min(r, rows - 1)
            pendingWrap = false

        case (0x4a, false): eraseInDisplay(mode: firstParam)   // ED
        case (0x4b, false): eraseInLine(mode: firstParam)      // EL
        case (0x4c, false): insertLines(count: max(1, firstParam))  // IL
        case (0x4d, false): deleteLines(count: max(1, firstParam))  // DL
        case (0x40, false): insertChars(count: max(1, firstParam))  // ICH
        case (0x50, false): deleteChars(count: max(1, firstParam))  // DCH
        case (0x58, false): eraseChars(count: max(1, firstParam))   // ECH

        case (0x53, false):                       // SU
            for _ in 0..<max(1, firstParam) { scrollGridUp() }
        case (0x54, false):                       // SD
            for _ in 0..<max(1, firstParam) { scrollGridDown() }

        case (0x73, false): saveCursor()
        case (0x75, false): restoreCursor()

        case (0x72, false):                       // DECSTBM (set scroll region)
            let top = max(1, params.count > 0 && params[0] != 0 ? params[0] : 1) - 1
            let bot = max(1, params.count > 1 && params[1] != 0 ? params[1] : rows) - 1
            if top < bot, bot < rows {
                scrollTop = top
                scrollBottom = bot
            } else {
                scrollTop = 0
                scrollBottom = rows - 1
            }
            grid.cursorRow = 0
            grid.cursorCol = 0
            pendingWrap = false

        case (0x68, true):                        // CSI ? Pn h — DEC set
            for p in params { setPrivateMode(p, enable: true) }
        case (0x6c, true):                        // CSI ? Pn l — DEC reset
            for p in params { setPrivateMode(p, enable: false) }

        case (0x6e, false) where firstParam == 6: // DSR cursor pos report
            let r = grid.cursorRow + 1
            let c = grid.cursorCol + 1
            let response = "\u{1b}[\(r);\(c)R"
            onWriteToPTY?(Data(response.utf8))

        default:
            break
        }
    }

    private func setPrivateMode(_ mode: Int, enable: Bool) {
        switch mode {
        case 25:
            cursorVisible = enable
            onCursorVisibilityChanged?(cursorVisible)
        case 47, 1047, 1049:
            // 1049 = save cursor + clear alt screen + switch (and reverse on
            // exit). 47/1047 are simpler variants; we treat them similarly
            // because almost every modern TUI drives 1049.
            switchAlternate(enable, savesCursor: mode == 1049)
        case 2004:
            bracketedPasteEnabled = enable
        default:
            // Autowrap (?7), origin mode (?6), focus events (?1004),
            // mouse modes (?1000/1002/1003/1006), etc. — silently ignored.
            break
        }
    }

    private func switchAlternate(_ toAlt: Bool, savesCursor: Bool) {
        if toAlt, !useAlternate {
            if savesCursor {
                savedRow = mainGrid.cursorRow
                savedCol = mainGrid.cursorCol
                savedAttrs = attrs
            }
            useAlternate = true
            for r in 0..<rows {
                for c in 0..<cols { altGrid.cells[r][c] = defaultCell }
            }
            altGrid.cursorRow = 0
            altGrid.cursorCol = 0
            scrollTop = 0
            scrollBottom = rows - 1
            pendingWrap = false
        } else if !toAlt, useAlternate {
            useAlternate = false
            scrollTop = 0
            scrollBottom = rows - 1
            pendingWrap = false
            if savesCursor {
                mainGrid.cursorRow = min(savedRow, rows - 1)
                mainGrid.cursorCol = min(savedCol, cols - 1)
                if let a = savedAttrs { attrs = a }
            }
        }
    }

    // MARK: - Erase / insert / delete

    private func eraseInDisplay(mode: Int) {
        switch mode {
        case 0:                                   // cursor → end of screen
            for c in grid.cursorCol..<cols { grid.cells[grid.cursorRow][c] = defaultCell }
            for r in (grid.cursorRow + 1)..<rows {
                for c in 0..<cols { grid.cells[r][c] = defaultCell }
            }
        case 1:                                   // start → cursor
            for r in 0..<grid.cursorRow {
                for c in 0..<cols { grid.cells[r][c] = defaultCell }
            }
            for c in 0...min(grid.cursorCol, cols - 1) {
                grid.cells[grid.cursorRow][c] = defaultCell
            }
        case 2, 3:                                // entire screen (3 = + scrollback, we ignore the latter)
            for r in 0..<rows {
                for c in 0..<cols { grid.cells[r][c] = defaultCell }
            }
        default: break
        }
        pendingWrap = false
    }

    private func eraseInLine(mode: Int) {
        switch mode {
        case 0:
            for c in grid.cursorCol..<cols { grid.cells[grid.cursorRow][c] = defaultCell }
        case 1:
            for c in 0...min(grid.cursorCol, cols - 1) { grid.cells[grid.cursorRow][c] = defaultCell }
        case 2:
            for c in 0..<cols { grid.cells[grid.cursorRow][c] = defaultCell }
        default: break
        }
        pendingWrap = false
    }

    private func insertLines(count: Int) {
        guard grid.cursorRow >= scrollTop, grid.cursorRow <= scrollBottom else { return }
        let n = min(count, scrollBottom - grid.cursorRow + 1)
        for r in stride(from: scrollBottom, through: grid.cursorRow + n, by: -1) {
            grid.cells[r] = grid.cells[r - n]
        }
        for r in grid.cursorRow..<(grid.cursorRow + n) {
            grid.cells[r] = Array(repeating: defaultCell, count: cols)
        }
        pendingWrap = false
    }

    private func deleteLines(count: Int) {
        guard grid.cursorRow >= scrollTop, grid.cursorRow <= scrollBottom else { return }
        let n = min(count, scrollBottom - grid.cursorRow + 1)
        for r in grid.cursorRow...(scrollBottom - n) {
            grid.cells[r] = grid.cells[r + n]
        }
        for r in (scrollBottom - n + 1)...scrollBottom {
            grid.cells[r] = Array(repeating: defaultCell, count: cols)
        }
        pendingWrap = false
    }

    private func insertChars(count: Int) {
        let n = min(count, cols - grid.cursorCol)
        guard n > 0 else { return }
        for c in stride(from: cols - 1, through: grid.cursorCol + n, by: -1) {
            grid.cells[grid.cursorRow][c] = grid.cells[grid.cursorRow][c - n]
        }
        for c in grid.cursorCol..<(grid.cursorCol + n) {
            grid.cells[grid.cursorRow][c] = defaultCell
        }
        pendingWrap = false
    }

    private func deleteChars(count: Int) {
        let n = min(count, cols - grid.cursorCol)
        guard n > 0 else { return }
        for c in grid.cursorCol..<(cols - n) {
            grid.cells[grid.cursorRow][c] = grid.cells[grid.cursorRow][c + n]
        }
        for c in (cols - n)..<cols {
            grid.cells[grid.cursorRow][c] = defaultCell
        }
        pendingWrap = false
    }

    private func eraseChars(count: Int) {
        let n = min(count, cols - grid.cursorCol)
        guard n > 0 else { return }
        for c in grid.cursorCol..<(grid.cursorCol + n) {
            grid.cells[grid.cursorRow][c] = defaultCell
        }
        pendingWrap = false
    }

    // MARK: - SGR

    private func applySGR(_ params: [Int]) {
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:  attrs = defaultCell
            case 1:  attrs.bold = true
            case 3:  attrs.italic = true
            case 4:  attrs.underline = true
            case 7:  attrs.inverse = true
            case 22: attrs.bold = false
            case 23: attrs.italic = false
            case 24: attrs.underline = false
            case 27: attrs.inverse = false
            case 30...37:  attrs.fg = ansi8Color(p - 30, bright: false)
            case 39:       attrs.fg = defaultCell.fg
            case 90...97:  attrs.fg = ansi8Color(p - 90, bright: true)
            case 40...47:  attrs.bg = ansi8Color(p - 40, bright: false)
            case 49:       attrs.bg = defaultCell.bg
            case 100...107: attrs.bg = ansi8Color(p - 100, bright: true)
            case 38:
                if i + 2 < params.count, params[i + 1] == 5 {
                    attrs.fg = xterm256Color(params[i + 2]); i += 2
                } else if i + 4 < params.count, params[i + 1] == 2 {
                    attrs.fg = NSColor(srgbRed: CGFloat(params[i+2]) / 255,
                                       green:   CGFloat(params[i+3]) / 255,
                                       blue:    CGFloat(params[i+4]) / 255,
                                       alpha: 1)
                    i += 4
                }
            case 48:
                if i + 2 < params.count, params[i + 1] == 5 {
                    attrs.bg = xterm256Color(params[i + 2]); i += 2
                } else if i + 4 < params.count, params[i + 1] == 2 {
                    attrs.bg = NSColor(srgbRed: CGFloat(params[i+2]) / 255,
                                       green:   CGFloat(params[i+3]) / 255,
                                       blue:    CGFloat(params[i+4]) / 255,
                                       alpha: 1)
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
            NSColor(srgbRed: 0.00, green: 0.00, blue: 0.00, alpha: 1),
            NSColor(srgbRed: 0.80, green: 0.20, blue: 0.20, alpha: 1),
            NSColor(srgbRed: 0.30, green: 0.75, blue: 0.30, alpha: 1),
            NSColor(srgbRed: 0.85, green: 0.75, blue: 0.20, alpha: 1),
            NSColor(srgbRed: 0.30, green: 0.55, blue: 0.85, alpha: 1),
            NSColor(srgbRed: 0.78, green: 0.40, blue: 0.78, alpha: 1),
            NSColor(srgbRed: 0.30, green: 0.78, blue: 0.78, alpha: 1),
            NSColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1),
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
        guard index >= 0, index < table.count else { return defaultCell.fg }
        return table[index]
    }

    private func xterm256Color(_ n: Int) -> NSColor {
        if n < 8  { return ansi8Color(n,     bright: false) }
        if n < 16 { return ansi8Color(n - 8, bright: true)  }
        if n < 232 {
            let v = n - 16
            let r = (v / 36) % 6, g = (v / 6) % 6, b = v % 6
            let levels: [CGFloat] = [0.0, 0.37, 0.53, 0.69, 0.84, 1.00]
            return NSColor(srgbRed: levels[r], green: levels[g], blue: levels[b], alpha: 1)
        }
        let t = CGFloat(n - 232) / 23.0
        return NSColor(srgbRed: t, green: t, blue: t, alpha: 1)
    }

    // MARK: - Storage rendering
    //
    // Rebuild the entire NSTextStorage on each parser pass. This is wasteful
    // for tiny mutations but simple and correct. For an 80×24 grid it's ~2KB
    // of attributed string per rebuild — easily fast enough for interactive
    // TUIs. If profiling shows it hurts, switch to per-row diffs.

    private func rebuildStorage() {
        let attributed = NSMutableAttributedString()
        let scrollbackPart = useAlternate ? [] : scrollback
        let allRows = scrollbackPart + grid.cells
        for (i, row) in allRows.enumerated() {
            for cell in row {
                var fg = cell.fg
                var bg = cell.bg
                if cell.inverse { swap(&fg, &bg) }
                var a: [NSAttributedString.Key: Any] = [
                    .font: fontFor(bold: cell.bold, italic: cell.italic),
                    .foregroundColor: fg,
                    .backgroundColor: bg,
                ]
                if cell.underline {
                    a[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                attributed.append(NSAttributedString(string: String(cell.char), attributes: a))
            }
            if i < allRows.count - 1 {
                attributed.append(NSAttributedString(string: "\n",
                                                     attributes: [.font: cellFont]))
            }
        }
        storage.beginEditing()
        storage.setAttributedString(attributed)
        storage.endEditing()
    }

    private func fontFor(bold: Bool, italic: Bool) -> NSFont {
        guard bold || italic else { return cellFont }
        let mgr = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if bold   { traits.insert(.boldFontMask)   }
        if italic { traits.insert(.italicFontMask) }
        return mgr.convert(cellFont, toHaveTrait: traits)
    }
}

// MARK: - Terminal text view (input handling)

final class TerminalTextView: NSTextView {
    /// Bytes to send to the PTY when the user types or pastes.
    var onInput: ((Data) -> Void)?
    /// Fires when the user clicks into the terminal — the pane uses this to
    /// mark itself as the active pane in the Editor coordinator.
    var onBecomeFirstResponder: (() -> Void)?
    /// Polled when the user pastes. When true, we wrap the pasted text with
    /// `\e[200~`/`\e[201~` so applications that opted into bracketed-paste
    /// mode (Claude Code, vim, fish) can detect and treat it as a single
    /// chunk rather than per-character input.
    var isBracketedPasteEnabled: () -> Bool = { false }

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
                    if isBracketedPasteEnabled() {
                        let wrapped = "\u{1b}[200~" + s + "\u{1b}[201~"
                        onInput?(Data(wrapped.utf8))
                    } else {
                        onInput?(Data(s.utf8))
                    }
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
    let emulator: TerminalEmulator
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
    /// Driven by `?25h`/`?25l`. When false, no cursor is drawn at all (and
    /// the blink timer doesn't toggle visibility).
    private var cursorEnabled: Bool = true
    private let cellWidth: CGFloat
    private let cellHeight: CGFloat
    /// Deferred-start guard. We only spawn the shell once we know the real
    /// viewport size — starting at the placeholder 24×80 leads to the first
    /// prompt being drawn at the wrong dimensions and the redraw on SIGWINCH
    /// often doesn't recover cleanly.
    private var sessionStarted: Bool = false

    init(session: TerminalSession, emulator: TerminalEmulator, font: NSFont) {
        self.session = session
        self.emulator = emulator
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

        // Bind the emulator's storage so the parser writes show up automatically.
        textView.layoutManager?.replaceTextStorage(emulator.storage)
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
        textView.isBracketedPasteEnabled = { [weak emulator] in
            return emulator?.bracketedPasteEnabled ?? false
        }

        // Scroll to bottom whenever the parser advances the buffer; gated by
        // a flag so the user can scroll up to read history without being
        // yanked back on every output chunk.
        emulator.onChange = { [weak self] in
            self?.handleBufferChanged()
        }
        emulator.onCursorVisibilityChanged = { [weak self] visible in
            self?.cursorEnabled = visible
            self?.applyCursorVisibility()
        }
        // CSI 6n (cursor position report) and similar — emulator hands us a
        // reply payload, we forward it to the shell so terminfo-driven apps
        // get an answer.
        emulator.onWriteToPTY = { [weak self] data in
            self?.session.write(data)
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
            guard self.cursorEnabled else {
                self.cursorView.isHidden = true
                return
            }
            self.cursorOn.toggle()
            self.cursorView.isHidden = !self.cursorOn
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    /// Reflect the emulator's ?25 state. When the cursor is hidden the
    /// overlay is forced off; when shown, the next blink tick brings it back.
    private func applyCursorVisibility() {
        if cursorEnabled {
            cursorOn = true
            cursorView.isHidden = false
        } else {
            cursorView.isHidden = true
        }
    }

    /// Place the overlay at the emulator cursor's pixel position. Called
    /// after every parser update so the block tracks input echo, BS-space-BS
    /// erase sequences, prompt redraws, and full-screen TUI cursor moves.
    /// Resets the blink phase so the cursor is visible right after activity
    /// instead of mid-off-cycle.
    private func updateCursorPosition() {
        guard let lm = textView.layoutManager,
              let container = textView.textContainer else { return }
        lm.ensureLayout(for: container)

        let length = emulator.storage.length
        let idx = min(emulator.cursorStorageIndex, max(0, length - (length > 0 ? 1 : 0)))
        let inset = textView.textContainerInset

        let rect: NSRect
        if length == 0 {
            rect = NSRect(x: 0, y: 0, width: cellWidth, height: cellHeight)
        } else {
            let glyphIdx = lm.glyphIndexForCharacter(at: idx)
            let charRect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1),
                                           in: container)
            rect = NSRect(x: charRect.minX, y: charRect.minY,
                          width: cellWidth, height: charRect.height)
        }

        let target = rect.offsetBy(dx: inset.width, dy: inset.height)
        // Skip implicit animation so the cursor snaps to its new spot — a
        // smoothly-tweened cursor reads as laggy in a terminal.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorView.frame = target
        CATransaction.commit()

        if cursorEnabled {
            cursorOn = true
            cursorView.isHidden = false
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Take focus when this view becomes active so typing goes straight to
    /// the shell. Called by the pane after swapping content.
    func focusInput() {
        window?.makeFirstResponder(textView)
    }

    private func handleBufferChanged() {
        // Keep the cursor in the viewport. We track the cursor's storage
        // index rather than storage end because, with a 30+ row grid and only
        // 5 lines of output, "storage end" lives in blank rows below the
        // cursor and would scroll the actual content out of view.
        textView.scrollRangeToVisible(NSRange(location: emulator.cursorStorageIndex, length: 0))
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

        // Wait for a real layout before doing anything — viewDidMoveToWindow
        // can fire while bounds is still zero, which would resolve to a 1×1
        // grid and confuse every shell on the planet.
        guard rows >= 4, cols >= 10 else { return }

        if rows == lastReportedRows, cols == lastReportedCols { return }
        lastReportedRows = rows
        lastReportedCols = cols
        emulator.resize(rows: rows, cols: cols)

        if sessionStarted {
            session.resize(rows: rows, cols: cols)
        } else {
            // First time we have a real size — spawn the shell now so it
            // paints its initial prompt at the correct dimensions instead
            // of starting at 24×80 and trying to recover via SIGWINCH.
            sessionStarted = true
            session.start(rows: rows, cols: cols)
        }
    }
}

// MARK: - Terminal state (lives on a DocumentTab when kind == .terminal)

final class TerminalState {
    let session: TerminalSession
    let emulator: TerminalEmulator
    let view: TerminalView
    /// Notifies the owning pane so it can close the tab automatically when
    /// the shell exits.
    var onShellExit: (() -> Void)?

    init(font: NSFont) {
        let session = TerminalSession()
        let emulator = TerminalEmulator(rows: 24, cols: 80, font: font,
                                        defaultFG: Theme.foreground,
                                        defaultBG: Theme.background)
        let view = TerminalView(session: session, emulator: emulator, font: font)
        self.session = session
        self.emulator = emulator
        self.view = view

        session.onOutput = { [weak emulator] data in
            emulator?.feed(data)
        }
        session.onExit = { [weak self] in
            self?.onShellExit?()
        }
    }

    /// No-op kept for source compatibility with the old API. The shell is
    /// now spawned by `TerminalView` the first time it gets a real layout
    /// size, so it doesn't see a placeholder PTY size on startup.
    func start() {}
}
