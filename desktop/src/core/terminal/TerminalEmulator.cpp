#include "TerminalEmulator.h"
#include <QDebug>
#include <QRegularExpression>

TerminalEmulator::TerminalEmulator(TerminalType type, int cols, int rows, QObject *parent)
    : QObject(parent)
    , m_type(type)
    , m_cols(cols)
    , m_rows(rows)
{
    // Initialize color table
    m_colorTable.resize(256);
    
    // Standard 16 colors
    m_colorTable[0] = QColor(0, 0, 0);         // Black
    m_colorTable[1] = QColor(205, 0, 0);       // Red
    m_colorTable[2] = QColor(0, 205, 0);       // Green
    m_colorTable[3] = QColor(205, 205, 0);     // Yellow
    m_colorTable[4] = QColor(0, 0, 238);       // Blue
    m_colorTable[5] = QColor(205, 0, 205);     // Magenta
    m_colorTable[6] = QColor(0, 205, 205);     // Cyan
    m_colorTable[7] = QColor(229, 229, 229);   // White
    m_colorTable[8] = QColor(127, 127, 127);   // Bright Black
    m_colorTable[9] = QColor(255, 0, 0);       // Bright Red
    m_colorTable[10] = QColor(0, 255, 0);      // Bright Green
    m_colorTable[11] = QColor(255, 255, 0);    // Bright Yellow
    m_colorTable[12] = QColor(92, 92, 255);    // Bright Blue
    m_colorTable[13] = QColor(255, 0, 255);    // Bright Magenta
    m_colorTable[14] = QColor(0, 255, 255);    // Bright Cyan
    m_colorTable[15] = QColor(255, 255, 255);  // Bright White
    
    // Initialize 216 color cube (16-231)
    for (int i = 0; i < 216; i++) {
        int r = (i / 36) % 6;
        int g = (i / 6) % 6;
        int b = i % 6;
        m_colorTable[16 + i] = QColor(
            r > 0 ? 55 + r * 40 : 0,
            g > 0 ? 55 + g * 40 : 0,
            b > 0 ? 55 + b * 40 : 0
        );
    }
    
    // Initialize grayscale (232-255)
    for (int i = 0; i < 24; i++) {
        int gray = 8 + i * 10;
        m_colorTable[232 + i] = QColor(gray, gray, gray);
    }
    
    // Default colors
    m_defaultForeground = m_colorTable[7];
    m_defaultBackground = m_colorTable[0];
    
    // Initialize screen buffer
    m_screen.lines.resize(m_rows);
    for (int i = 0; i < m_rows; i++) {
        m_screen.lines[i].resize(m_cols);
    }
    
    m_screen.scrollBottom = m_rows - 1;
    
    // Initialize tab stops (every 8 columns)
    m_tabStops.resize(m_cols);
    for (int i = 0; i < m_cols; i += 8) {
        m_tabStops[i] = true;
    }
}

TerminalEmulator::~TerminalEmulator()
{
}

void TerminalEmulator::setTerminalType(TerminalType type)
{
    m_type = type;
    reset();
}

void TerminalEmulator::resize(int cols, int rows)
{
    m_cols = cols;
    m_rows = rows;
    
    m_screen.lines.resize(m_rows);
    for (int i = 0; i < m_rows; i++) {
        m_screen.lines[i].resize(m_cols);
    }
    
    m_screen.scrollBottom = m_rows - 1;
    m_tabStops.resize(m_cols);
    
    emit screenChanged();
}

void TerminalEmulator::feed(const QByteArray& data)
{
    for (char c : data) {
        switch (m_parserState) {
            case ParserState::Ground:
                if (c == 0x1B) {  // ESC
                    m_parserState = ParserState::Escape;
                    m_escapeSequence.clear();
                } else if (c < 0x20) {
                    parseControlCharacter(c);
                } else {
                    printCharacter(QChar(c));
                }
                break;
                
            case ParserState::Escape:
                m_escapeSequence.append(c);
                if (c == '[') {
                    m_parserState = ParserState::CSI_Entry;
                    m_csiParams.clear();
                } else if (c == ']') {
                    m_parserState = ParserState::OSC_Entry;
                    m_oscString.clear();
                } else if (c == 'P') {
                    m_parserState = ParserState::DCS_Entry;
                } else {
                    parseEscapeSequence(m_escapeSequence);
                    m_parserState = ParserState::Ground;
                }
                break;
                
            case ParserState::CSI_Entry:
                if (c >= '0' && c <= '9') {
                    m_parserState = ParserState::CSI_Param;
                    long param = c - '0';
                    m_csiParams.append(param);
                } else if (c == ';') {
                    m_parserState = ParserState::CSI_Param;
                    m_csiParams.append(0);
                } else if (c >= 0x20 && c <= 0x2F) {
                    m_parserState = ParserState::CSI_Intermediate;
                } else if (c >= '@' && c <= '~') {
                    handleCSI(m_csiParams, QChar(c));
                    m_parserState = ParserState::Ground;
                } else {
                    m_parserState = ParserState::Ground;
                }
                break;
                
            case ParserState::CSI_Param:
                if (c >= '0' && c <= '9') {
                    if (!m_csiParams.isEmpty()) {
                        m_csiParams.last() = m_csiParams.last() * 10 + (c - '0');
                    }
                } else if (c == ';') {
                    m_csiParams.append(0);
                } else if (c >= '@' && c <= '~') {
                    handleCSI(m_csiParams, QChar(c));
                    m_parserState = ParserState::Ground;
                } else {
                    m_parserState = ParserState::Ground;
                }
                break;
                
            case ParserState::CSI_Intermediate:
                if (c >= '@' && c <= '~') {
                    handleCSI(m_csiParams, QChar(c));
                    m_parserState = ParserState::Ground;
                } else if (c < 0x20 || c > 0x2F) {
                    m_parserState = ParserState::Ground;
                }
                break;
                
            case ParserState::OSC_Entry:
                if (c == 0x07) {  // BEL
                    handleOSC(m_oscString);
                    m_parserState = ParserState::Ground;
                } else if (c == 0x1B) {
                    m_parserState = ParserState::Escape;
                } else {
                    m_oscString.append(c);
                    m_parserState = ParserState::OSC_String;
                }
                break;
                
            case ParserState::OSC_String:
                if (c == 0x07) {  // BEL
                    handleOSC(m_oscString);
                    m_parserState = ParserState::Ground;
                } else if (c == 0x1B) {
                    m_parserState = ParserState::Escape;
                } else {
                    m_oscString.append(c);
                }
                break;
                
            default:
                m_parserState = ParserState::Ground;
                break;
        }
    }
}

void TerminalEmulator::parseControlCharacter(char c)
{
    switch (c) {
        case 0x07:  // BEL
            emit bell();
            break;
        case 0x08:  // BS (Backspace)
            if (m_screen.cursorX > 0) {
                m_screen.cursorX--;
            }
            break;
        case 0x09:  // HT (Tab)
            for (int i = m_screen.cursorX + 1; i < m_cols; i++) {
                if (m_tabStops[i]) {
                    m_screen.cursorX = i;
                    return;
                }
            }
            m_screen.cursorX = m_cols - 1;
            break;
        case 0x0A:  // LF
        case 0x0B:  // VT
        case 0x0C:  // FF
            if (m_screen.cursorY >= m_screen.scrollBottom) {
                scrollUp();
            } else {
                m_screen.cursorY++;
            }
            break;
        case 0x0D:  // CR
            m_screen.cursorX = 0;
            break;
        case 0x0E:  // SO (Shift Out)
            // Switch to G1 character set
            break;
        case 0x0F:  // SI (Shift In)
            // Switch to G0 character set
            break;
    }
}

void TerminalEmulator::printCharacter(QChar c)
{
    if (m_screen.cursorX >= m_cols) {
        if (m_autoWrap) {
            m_screen.cursorX = 0;
            if (m_screen.cursorY >= m_screen.scrollBottom) {
                scrollUp();
            } else {
                m_screen.cursorY++;
            }
        } else {
            m_screen.cursorX = m_cols - 1;
        }
    }
    
    TerminalCell cell;
    cell.character = c;
    cell.attributes.foreground = m_defaultForeground;
    cell.attributes.background = m_defaultBackground;
    
    updateCell(m_screen.cursorY, m_screen.cursorX, cell);
    m_screen.cursorX++;
}

void TerminalEmulator::handleCSI(const QVector<long>& params, QChar finalChar)
{
    switch (finalChar.toLatin1()) {
        case 'A': {  // CUU - Cursor Up
            int count = params.isEmpty() || params[0] == 0 ? 1 : params[0];
            m_screen.cursorY = qMax(0, m_screen.cursorY - count);
            emit cursorMoved(m_screen.cursorX, m_screen.cursorY);
            break;
        }
        case 'B': {  // CUD - Cursor Down
            int count = params.isEmpty() || params[0] == 0 ? 1 : params[0];
            m_screen.cursorY = qMin(m_rows - 1, m_screen.cursorY + count);
            emit cursorMoved(m_screen.cursorX, m_screen.cursorY);
            break;
        }
        case 'C': {  // CUF - Cursor Forward
            int count = params.isEmpty() || params[0] == 0 ? 1 : params[0];
            m_screen.cursorX = qMin(m_cols - 1, m_screen.cursorX + count);
            emit cursorMoved(m_screen.cursorX, m_screen.cursorY);
            break;
        }
        case 'D': {  // CUB - Cursor Back
            int count = params.isEmpty() || params[0] == 0 ? 1 : params[0];
            m_screen.cursorX = qMax(0, m_screen.cursorX - count);
            emit cursorMoved(m_screen.cursorX, m_screen.cursorY);
            break;
        }
        case 'H':  // CUP - Cursor Position
        case 'f':  // HVP - Horizontal and Vertical Position
        {
            int row = (params.isEmpty() || params[0] == 0) ? 1 : params[0];
            int col = (params.size() < 2 || params[1] == 0) ? 1 : params[1];
            m_screen.cursorY = qBound(0, row - 1, m_rows - 1);
            m_screen.cursorX = qBound(0, col - 1, m_cols - 1);
            emit cursorMoved(m_screen.cursorX, m_screen.cursorY);
            break;
        }
        case 'J': {  // ED - Erase in Display
            int mode = params.isEmpty() ? 0 : params[0];
            clearLine(mode);
            break;
        }
        case 'K': {  // EL - Erase in Line
            int mode = params.isEmpty() ? 0 : params[0];
            clearLine(mode);
            break;
        }
        case 'm': {  // SGR - Select Graphic Rendition
            if (params.isEmpty()) {
                // Reset attributes
                break;
            }
            
            for (long param : params) {
                if (param == 0) {
                    // Reset
                } else if (param == 1) {
                    // Bold
                } else if (param == 3) {
                    // Italic
                } else if (param == 4) {
                    // Underline
                } else if (param == 5) {
                    // Blink
                } else if (param == 7) {
                    // Reverse
                } else if (param == 8) {
                    // Invisible
                } else if (param == 9) {
                    // Strikethrough
                } else if (param >= 30 && param <= 37) {
                    // Foreground color
                } else if (param == 38 && params.size() >= 3) {
                    // Extended foreground color
                } else if (param >= 40 && param <= 47) {
                    // Background color
                } else if (param == 48 && params.size() >= 3) {
                    // Extended background color
                }
            }
            break;
        }
        case 'n': {  // DSR - Device Status Report
            if (params.size() == 1 && params[0] == 6) {
                // Report cursor position
                QString response = QString("\033[%1;%2R").arg(m_screen.cursorY + 1).arg(m_screen.cursorX + 1);
                emit sendData(response.toUtf8());
            }
            break;
        }
        case 's':  // Save cursor
            break;
        case 'u':  // Restore cursor
            break;
        case '@': {  // ICH - Insert Character
            int count = params.isEmpty() || params[0] == 0 ? 1 : params[0];
            insertCharacters(count);
            break;
        }
        case 'P': {  // DCH - Delete Character
            int count = params.isEmpty() || params[0] == 0 ? 1 : params[0];
            deleteCharacters(count);
            break;
        }
        case 'L': {  // IL - Insert Line
            int count = params.isEmpty() || params[0] == 0 ? 1 : params[0];
            insertLines(count);
            break;
        }
        case 'M': {  // DL - Delete Line
            int count = params.isEmpty() || params[0] == 0 ? 1 : params[0];
            deleteLines(count);
            break;
        }
        case 'X': {  // ECH - Erase Character
            int count = params.isEmpty() || params[0] == 0 ? 1 : params[0];
            eraseCharacters(count);
            break;
        }
        case 'g': {  // TBC - Tab Clear
            int mode = params.isEmpty() ? 0 : params[0];
            if (mode == 0) {
                clearTabStop();
            } else if (mode == 3) {
                m_tabStops.fill(false);
            }
            break;
        }
        case 'r': {  // DECSTBM - Set Scroll Region
            int top = (params.isEmpty() || params[0] == 0) ? 1 : params[0];
            int bottom = (params.size() < 2 || params[1] == 0) ? m_rows : params[1];
            m_screen.scrollTop = qBound(0, top - 1, m_rows - 1);
            m_screen.scrollBottom = qBound(0, bottom - 1, m_rows - 1);
            break;
        }
    }
}

void TerminalEmulator::handleOSC(const QByteArray& params)
{
    // OSC sequences for title, colors, etc.
    if (params.startsWith("0;") || params.startsWith("2;")) {
        // Set window title
        QString title = QString::fromUtf8(params.mid(2));
        emit titleChanged(title);
    }
}

void TerminalEmulator::handleDECPrivate(const QVector<long>& params, QChar finalChar)
{
    if (params.isEmpty()) return;
    
    int mode = params[0];
    bool set = (finalChar == 'h');
    
    switch (mode) {
        case 1:  // Application cursor keys
            m_applicationCursorKeys = set;
            break;
        case 3:  // 132 column mode
            break;
        case 5:  // Reverse video
            break;
        case 6:  // Origin mode
            m_originMode = set;
            break;
        case 7:  // Auto-wrap
            m_autoWrap = set;
            break;
        case 12:  // Cursor blink
            break;
        case 25:  // Show/hide cursor
            m_screen.cursorVisible = set;
            break;
        case 1000:  // Mouse tracking
            m_mouseTracking = set;
            break;
        case 1006:  // SGR mouse mode
            m_mouseSgrExt = set;
            break;
        case 2004:  // Bracketed paste
            m_bracketedPasteMode = set;
            break;
    }
    
    emit modeChanged();
}

void TerminalEmulator::clearScreen()
{
    for (int row = 0; row < m_rows; row++) {
        for (int col = 0; col < m_cols; col++) {
            TerminalCell cell;
            cell.character = ' ';
            cell.attributes.foreground = m_defaultForeground;
            cell.attributes.background = m_defaultBackground;
            updateCell(row, col, cell);
        }
    }
    m_screen.cursorX = 0;
    m_screen.cursorY = 0;
}

void TerminalEmulator::clearLine(int mode)
{
    switch (mode) {
        case 0:  // Clear from cursor to end of line
            for (int col = m_screen.cursorX; col < m_cols; col++) {
                TerminalCell cell;
                cell.character = ' ';
                cell.attributes.foreground = m_defaultForeground;
                cell.attributes.background = m_defaultBackground;
                updateCell(m_screen.cursorY, col, cell);
            }
            break;
        case 1:  // Clear from start of line to cursor
            for (int col = 0; col <= m_screen.cursorX; col++) {
                TerminalCell cell;
                cell.character = ' ';
                cell.attributes.foreground = m_defaultForeground;
                cell.attributes.background = m_defaultBackground;
                updateCell(m_screen.cursorY, col, cell);
            }
            break;
        case 2:  // Clear entire line
            for (int col = 0; col < m_cols; col++) {
                TerminalCell cell;
                cell.character = ' ';
                cell.attributes.foreground = m_defaultForeground;
                cell.attributes.background = m_defaultBackground;
                updateCell(m_screen.cursorY, col, cell);
            }
            break;
    }
}

void TerminalEmulator::scrollUp()
{
    // Move lines up in scroll region
    for (int row = m_screen.scrollTop; row < m_screen.scrollBottom; row++) {
        m_screen.lines[row] = m_screen.lines[row + 1];
    }
    
    // Clear bottom line
    for (int col = 0; col < m_cols; col++) {
        TerminalCell cell;
        cell.character = ' ';
        cell.attributes.foreground = m_defaultForeground;
        cell.attributes.background = m_defaultBackground;
        updateCell(m_screen.scrollBottom, col, cell);
    }
}

void TerminalEmulator::scrollDown()
{
    // Move lines down in scroll region
    for (int row = m_screen.scrollBottom; row > m_screen.scrollTop; row--) {
        m_screen.lines[row] = m_screen.lines[row - 1];
    }
    
    // Clear top line
    for (int col = 0; col < m_cols; col++) {
        TerminalCell cell;
        cell.character = ' ';
        cell.attributes.foreground = m_defaultForeground;
        cell.attributes.background = m_defaultBackground;
        updateCell(m_screen.scrollTop, col, cell);
    }
}

void TerminalEmulator::insertLines(int count)
{
    for (int i = 0; i < count; i++) {
        scrollDown();
    }
}

void TerminalEmulator::deleteLines(int count)
{
    for (int i = 0; i < count; i++) {
        scrollUp();
    }
}

void TerminalEmulator::insertCharacters(int count)
{
    for (int i = m_cols - 1; i >= m_screen.cursorX + count; i--) {
        m_screen.lines[m_screen.cursorY][i] = m_screen.lines[m_screen.cursorY][i - count];
    }
    for (int i = m_screen.cursorX; i < m_screen.cursorX + count && i < m_cols; i++) {
        TerminalCell cell;
        cell.character = ' ';
        cell.attributes.foreground = m_defaultForeground;
        cell.attributes.background = m_defaultBackground;
        updateCell(m_screen.cursorY, i, cell);
    }
}

void TerminalEmulator::deleteCharacters(int count)
{
    for (int i = m_screen.cursorX; i < m_cols - count; i++) {
        m_screen.lines[m_screen.cursorY][i] = m_screen.lines[m_screen.cursorY][i + count];
    }
    for (int i = m_cols - count; i < m_cols; i++) {
        TerminalCell cell;
        cell.character = ' ';
        cell.attributes.foreground = m_defaultForeground;
        cell.attributes.background = m_defaultBackground;
        updateCell(m_screen.cursorY, i, cell);
    }
}

void TerminalEmulator::eraseCharacters(int count)
{
    for (int i = m_screen.cursorX; i < m_screen.cursorX + count && i < m_cols; i++) {
        TerminalCell cell;
        cell.character = ' ';
        cell.attributes.foreground = m_defaultForeground;
        cell.attributes.background = m_defaultBackground;
        updateCell(m_screen.cursorY, i, cell);
    }
}

void TerminalEmulator::setTabStop()
{
    if (m_screen.cursorX >= 0 && m_screen.cursorX < m_cols) {
        m_tabStops[m_screen.cursorX] = true;
    }
}

void TerminalEmulator::clearTabStop()
{
    if (m_screen.cursorX >= 0 && m_screen.cursorX < m_cols) {
        m_tabStops[m_screen.cursorX] = false;
    }
}

void TerminalEmulator::updateCell(int row, int col, const TerminalCell& cell)
{
    if (row >= 0 && row < m_rows && col >= 0 && col < m_cols) {
        m_screen.lines[row][col] = cell;
        emit screenChanged();
    }
}

void TerminalEmulator::moveCursor(int x, int y)
{
    m_screen.cursorX = qBound(0, x, m_cols - 1);
    m_screen.cursorY = qBound(0, y, m_rows - 1);
    emit cursorMoved(m_screen.cursorX, m_screen.cursorY);
}

void TerminalEmulator::showCursor(bool show)
{
    m_screen.cursorVisible = show;
}

void TerminalEmulator::setSelection(int startRow, int startCol, int endRow, int endCol)
{
    m_selectionStartRow = startRow;
    m_selectionStartCol = startCol;
    m_selectionEndRow = endRow;
    m_selectionEndCol = endCol;
    m_hasSelection = true;
    emit selectionChanged();
}

void TerminalEmulator::clearSelection()
{
    m_hasSelection = false;
    emit selectionChanged();
}

void TerminalEmulator::setScrollbackSize(int size)
{
    m_scrollbackSize = size;
}

void TerminalEmulator::scrollUp(int lines)
{
    for (int i = 0; i < lines; i++) {
        scrollUp();
    }
}

void TerminalEmulator::scrollDown(int lines)
{
    for (int i = 0; i < lines; i++) {
        scrollDown();
    }
}

void TerminalEmulator::setDefaultColors(const QColor& fg, const QColor& bg)
{
    m_defaultForeground = fg;
    m_defaultBackground = bg;
}

void TerminalEmulator::setFont(const QFont& font)
{
    m_font = font;
}

void TerminalEmulator::setApplicationCursorKeys(bool enable)
{
    m_applicationCursorKeys = enable;
}

void TerminalEmulator::setAlternateScreenBuffer(bool enable)
{
    if (enable && !m_usingAlternateScreen) {
        m_alternateScreen = m_screen;
        m_usingAlternateScreen = true;
    } else if (!enable && m_usingAlternateScreen) {
        m_screen = m_alternateScreen;
        m_usingAlternateScreen = false;
    }
}

void TerminalEmulator::setBracketedPasteMode(bool enable)
{
    m_bracketedPasteMode = enable;
}

void TerminalEmulator::setMouseTracking(bool enable)
{
    m_mouseTracking = enable;
}

void TerminalEmulator::reset()
{
    m_screen.cursorX = 0;
    m_screen.cursorY = 0;
    m_screen.cursorVisible = true;
    m_screen.scrollTop = 0;
    m_screen.scrollBottom = m_rows - 1;
    
    clearScreen();
    
    m_applicationCursorKeys = false;
    m_bracketedPasteMode = false;
    m_mouseTracking = false;
    m_autoWrap = true;
    m_insertMode = false;
    m_originMode = false;
    
    m_tabStops.fill(false);
    for (int i = 0; i < m_cols; i += 8) {
        m_tabStops[i] = true;
    }
    
    emit screenChanged();
}

void TerminalEmulator::softReset()
{
    m_screen.cursorX = 0;
    m_screen.cursorY = 0;
    m_screen.cursorVisible = true;
    m_applicationCursorKeys = false;
    m_bracketedPasteMode = false;
    m_mouseTracking = false;
    m_autoWrap = true;
    m_insertMode = false;
    m_originMode = false;
}

QString TerminalEmulator::getScreenText() const
{
    QString text;
    for (int row = 0; row < m_rows; row++) {
        for (int col = 0; col < m_cols; col++) {
            text += m_screen.lines[row][col].character;
        }
        text += '\n';
    }
    return text;
}

QString TerminalEmulator::getSelectedText() const
{
    if (!m_hasSelection) return QString();
    
    QString text;
    int startRow = qMin(m_selectionStartRow, m_selectionEndRow);
    int endRow = qMax(m_selectionStartRow, m_selectionEndRow);
    int startCol = qMin(m_selectionStartCol, m_selectionEndCol);
    int endCol = qMax(m_selectionStartCol, m_selectionEndCol);
    
    for (int row = startRow; row <= endRow; row++) {
        int colStart = (row == startRow) ? startCol : 0;
        int colEnd = (row == endRow) ? endCol : m_cols - 1;
        
        for (int col = colStart; col <= colEnd; col++) {
            text += m_screen.lines[row][col].character;
        }
        if (row < endRow) text += '\n';
    }
    
    return text;
}

void TerminalEmulator::parseEscapeSequence(const QByteArray& sequence)
{
    // Handle escape sequences
    if (sequence.size() >= 2) {
        char second = sequence[1];
        switch (second) {
            case 'D':  // Index
                scrollUp();
                break;
            case 'M':  // Reverse Index
                scrollDown();
                break;
            case 'E':  // Next Line
                m_screen.cursorX = 0;
                if (m_screen.cursorY >= m_screen.scrollBottom) {
                    scrollUp();
                } else {
                    m_screen.cursorY++;
                }
                break;
            case 'H':  // Tab Set
                setTabStop();
                break;
            case 'c':  // Reset
                reset();
                break;
            case '7':  // Save Cursor
                break;
            case '8':  // Restore Cursor
                break;
            case '=':  // Application Keypad
                break;
            case '>':  // Normal Keypad
                break;
        }
    }
}
