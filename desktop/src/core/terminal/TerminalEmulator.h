#ifndef TERMINAL_EMULATOR_H
#define TERMINAL_EMULATOR_H

#include <QObject>
#include <QString>
#include <QByteArray>
#include <QColor>
#include <QFont>
#include <QVector>
#include <functional>

/**
 * Terminal type enumeration
 */
enum class TerminalType {
    XTerm,      // xterm-256color with true color
    VT100,      // DEC VT100 compatibility
    BVTerm      // BlueSSH enhanced terminal
};

/**
 * Terminal cell attributes
 */
struct CellAttributes {
    QColor foreground;
    QColor background;
    bool bold = false;
    bool italic = false;
    bool underline = false;
    bool blink = false;
    bool reverse = false;
    bool invisible = false;
    bool strikethrough = false;
};

/**
 * Terminal cell
 */
struct TerminalCell {
    QChar character;
    CellAttributes attributes;
    bool wide = false;  // Double-width character
};

/**
 * Terminal screen buffer
 */
struct ScreenBuffer {
    QVector<QVector<TerminalCell>> lines;
    int cursorX = 0;
    int cursorY = 0;
    bool cursorVisible = true;
    int scrollTop = 0;
    int scrollBottom = 0;
};

/**
 * Terminal Emulator - Base class for terminal emulation
 * Supports xterm, vt100, and bvterm terminal types
 */
class TerminalEmulator : public QObject
{
    Q_OBJECT

public:
    explicit TerminalEmulator(TerminalType type, int cols = 80, int rows = 24, QObject *parent = nullptr);
    virtual ~TerminalEmulator();

    // Terminal configuration
    void setTerminalType(TerminalType type);
    TerminalType getTerminalType() const { return m_type; }
    
    // Screen dimensions
    void resize(int cols, int rows);
    int getColumns() const { return m_cols; }
    int getRows() const { return m_rows; }

    // Input/Output
    void feed(const QByteArray& data);
    QByteArray getOutput() const;
    
    // Screen access
    const ScreenBuffer& getScreen() const { return m_screen; }
    QString getScreenText() const;
    QString getSelectedText() const;
    
    // Cursor control
    void moveCursor(int x, int y);
    void showCursor(bool show);
    
    // Selection
    void setSelection(int startRow, int startCol, int endRow, int endCol);
    void clearSelection();
    
    // Scrollback
    void setScrollbackSize(int size);
    int getScrollbackSize() const { return m_scrollbackSize; }
    void scrollUp(int lines);
    void scrollDown(int lines);
    
    // Attributes
    void setDefaultColors(const QColor& fg, const QColor& bg);
    void setFont(const QFont& font);
    
    // Terminal modes
    void setApplicationCursorKeys(bool enable);
    void setAlternateScreenBuffer(bool enable);
    void setBracketedPasteMode(bool enable);
    void setMouseTracking(bool enable);
    
    // Reset
    void reset();
    void softReset();

signals:
    void screenChanged();
    void titleChanged(const QString& title);
    void bell();
    void cursorMoved(int x, int y);
    void selectionChanged();
    void modeChanged();
    void sendData(const QByteArray& data);

protected:
    // Virtual methods for terminal-specific behavior
    virtual void parseEscapeSequence(const QByteArray& sequence);
    virtual void parseControlCharacter(char c);
    virtual void printCharacter(QChar c);
    virtual void handleCSI(const QVector<long>& params, QChar finalChar);
    virtual void handleOSC(const QByteArray& params);
    virtual void handleDECPrivate(const QVector<long>& params, QChar finalChar);
    
    // Screen manipulation
    void clearScreen();
    void clearLine(int mode);
    void insertLines(int count);
    void deleteLines(int count);
    void insertCharacters(int count);
    void deleteCharacters(int count);
    void eraseCharacters(int count);
    void scrollUp();
    void scrollDown();
    void setTabStop();
    void clearTabStop();
    
    // Character output
    void putChar(QChar c);
    void updateCell(int row, int col, const TerminalCell& cell);
    
    // State
    TerminalType m_type;
    int m_cols;
    int m_rows;
    int m_scrollbackSize = 10000;
    
    ScreenBuffer m_screen;
    ScreenBuffer m_alternateScreen;
    bool m_usingAlternateScreen = false;
    
    // Parser state
    enum class ParserState {
        Ground,
        Escape,
        CSI_Entry,
        CSI_Param,
        CSI_Intermediate,
        OSC_Entry,
        OSC_String,
        DCS_Entry,
        DCS_Param,
        DCS_Passthrough
    };
    
    ParserState m_parserState = ParserState::Ground;
    QByteArray m_escapeSequence;
    QVector<long> m_csiParams;
    QByteArray m_oscString;
    
    // Terminal modes
    bool m_applicationCursorKeys = false;
    bool m_bracketedPasteMode = false;
    bool m_mouseTracking = false;
    bool m_mouseSgrExt = false;
    bool m_autoWrap = true;
    bool m_insertMode = false;
    bool m_originMode = false;
    
    // Colors
    QColor m_defaultForeground;
    QColor m_defaultBackground;
    QVector<QColor> m_colorTable;  // 256 colors + true color
    
    // Tabs
    QVector<bool> m_tabStops;
    
    // Selection
    int m_selectionStartRow = -1;
    int m_selectionStartCol = -1;
    int m_selectionEndRow = -1;
    int m_selectionEndCol = -1;
    bool m_hasSelection = false;
    
    // Font
    QFont m_font;
};

#endif // TERMINAL_EMULATOR_H
