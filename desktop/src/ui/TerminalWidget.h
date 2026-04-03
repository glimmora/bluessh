#ifndef TERMINALWIDGET_H
#define TERMINALWIDGET_H

#include <QWidget>
#include <QByteArray>
#include <QColor>
#include <QFont>
#include <QKeyEvent>
#include <QPaintEvent>
#include <QResizeEvent>
#include <QTimer>
#include <vterm.h>

class SshSession;
class SearchBar;

/**
 * Terminal Widget - Full xterm-256color emulation using libvterm
 * Features:
 * - 24-bit true color support
 * - Unicode/UTF-8 support
 * - Mouse tracking
 * - Bracketed paste mode
 * - 10,000+ line scrollback
 * - Session recording
 */
class TerminalWidget : public QWidget
{
    Q_OBJECT

public:
    explicit TerminalWidget(QWidget *parent = nullptr);
    ~TerminalWidget();

    // Attach to SSH session
    bool attach(SshSession* session);
    
    // Detach from SSH session
    void detach();

    // Write data to terminal
    void write(const QByteArray& data);
    
    // Write string to terminal
    void write(const QString& text);

    // Resize terminal
    void resizeTerminal(int cols, int rows);

    // Search in terminal
    void search(const QString& query);
    void searchNext();
    void searchPrevious();
    void clearSearch();

    // Get selected text
    QString getSelectedText() const;

    // Copy selection to clipboard
    void copySelection();
    
    // Paste from clipboard
    void pasteFromClipboard();

    // Clear terminal
    void clear();

    // Set font
    void setTerminalFont(const QFont& font);
    
    // Set colors
    void setTerminalColors(const QColor& foreground, const QColor& background);

    // Recording
    void startRecording(const QString& filePath);
    void stopRecording();
    bool isRecording() const { return m_isRecording; }

signals:
    void titleChanged(const QString& title);
    void bell();
    void connectionLost();
    void recordingStarted();
    void recordingStopped();

protected:
    void paintEvent(QPaintEvent *event) override;
    void keyPressEvent(QKeyEvent *event) override;
    void keyReleaseEvent(QKeyEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void wheelEvent(QWheelEvent *event) override;
    void resizeEvent(QResizeEvent *event) override;
    void focusInEvent(QFocusEvent *event) override;
    void focusOutEvent(QFocusEvent *event) override;
    void contextMenuEvent(QContextMenuEvent *event) override;

private:
    void initializeVTerm();
    void updateScreen();
    void renderCell(int row, int col, QPainter& painter);
    void handleMouseSelection(QMouseEvent* event);
    void handleKeyboardInput(QKeyEvent* event);
    void sendKeepAlive();
    void updateScrollPosition();

    // libvterm
    VTerm* m_vterm = nullptr;
    VTermScreen* m_vtermScreen = nullptr;
    VTermState* m_vtermState = nullptr;

    // SSH session
    SshSession* m_sshSession = nullptr;

    // Terminal state
    int m_cols = 80;
    int m_rows = 24;
    int m_scrollbackSize = 10000;
    int m_scrollPosition = 0;
    bool m_isRecording = false;

    // Selection
    int m_selectionStartRow = -1;
    int m_selectionStartCol = -1;
    int m_selectionEndRow = -1;
    int m_selectionEndCol = -1;
    bool m_isSelecting = false;

    // Search
    QString m_searchQuery;
    int m_searchPosition = 0;
    QList<QPair<int, int>> m_searchMatches;

    // Appearance
    QFont m_terminalFont;
    QColor m_foregroundColor;
    QColor m_backgroundColor;
    QColor m_cursorColor;
    QColor m_selectionColor;

    // Timers
    QTimer* m_keepAliveTimer;
    QTimer* m_blinkTimer;
    bool m_cursorVisible = true;

    // Recording file
    QFile* m_recordingFile = nullptr;
    qint64 m_recordingStartTime = 0;
};

#endif // TERMINALWIDGET_H
