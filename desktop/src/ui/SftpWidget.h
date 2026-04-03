#ifndef SFTP_WIDGET_H
#define SFTP_WIDGET_H

#include <QWidget>
#include <QTreeView>
#include <QListView>
#include <QSplitter>
#include <QToolBar>
#include <QStatusBar>
#include <QLineEdit>
#include <QLabel>
#include <QProgressBar>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QMimeData>
#include <QFileInfo>
#include <QTimer>
#include <memory>

class SftpClient;
class SftpModel;
class TransferQueue;

/**
 * Transfer item for queue
 */
struct TransferItem {
    QString localPath;
    QString remotePath;
    qint64 size;
    qint64 transferred;
    bool isUpload;
    bool isPaused;
    bool isComplete;
    bool hasError;
    QString error;
    QDateTime startTime;
    QDateTime endTime;
};

/**
 * Graphical SFTP Interface with drag-and-drop support
 * Features:
 * - Dual-pane file browser (local/remote)
 * - Drag-and-drop transfers
 * - Transfer queue with pause/resume
 * - File permissions editor
 * - Remote file editing
 * - Transfer progress tracking
 */
class SftpWidget : public QWidget
{
    Q_OBJECT

public:
    explicit SftpWidget(SftpClient* sftpClient, QWidget *parent = nullptr);
    ~SftpWidget();

    // Navigate to remote path
    void navigateTo(const QString& path);
    
    // Refresh current directory
    void refresh();
    
    // Get current remote path
    QString getCurrentPath() const { return m_currentRemotePath; }

signals:
    void directoryChanged(const QString& path);
    void transferStarted(const TransferItem& item);
    void transferProgress(const TransferItem& item);
    void transferComplete(const TransferItem& item);
    void transferError(const TransferItem& item);
    void errorOccurred(const QString& error);

protected:
    void dragEnterEvent(QDragEnterEvent *event) override;
    void dragMoveEvent(QDragMoveEvent *event) override;
    void dropEvent(QDropEvent *event) override;
    void dragLeaveEvent(QDragLeaveEvent *event) override;

private slots:
    // Navigation
    void onLocalPathChanged(const QString& path);
    void onRemotePathChanged(const QString& path);
    void onLocalDoubleClicked(const QModelIndex& index);
    void onRemoteDoubleClicked(const QModelIndex& index);
    void onNavigateUp();
    void onNavigateHome();
    void onNavigateRoot();
    
    // File operations
    void onUploadFiles(const QStringList& localPaths);
    void onDownloadFiles(const QStringList& remotePaths);
    void onDeleteFiles(const QStringList& remotePaths);
    void onRenameFile(const QString& oldPath, const QString& newPath);
    void onCreateDirectory(const QString& path);
    void onChangePermissions(const QString& path, int permissions);
    
    // Transfer queue
    void onStartTransfer(const TransferItem& item);
    void onPauseTransfer(const QString& transferId);
    void onResumeTransfer(const QString& transferId);
    void onCancelTransfer(const QString& transferId);
    void onTransferProgress(qint64 bytesTransferred, qint64 totalBytes);
    void onTransferComplete();
    
    // Context menu
    void onLocalContextMenu(const QPoint& pos);
    void onRemoteContextMenu(const QPoint& pos);
    
    // Selection changes
    void onLocalSelectionChanged(const QItemSelection& selected, const QItemSelection& deselected);
    void onRemoteSelectionChanged(const QItemSelection& selected, const QItemSelection& deselected);

private:
    void setupUi();
    void setupLocalView();
    void setupRemoteView();
    void setupTransferQueue();
    void setupToolBar();
    void setupStatusBar();
    void loadLocalDirectory(const QString& path);
    void loadRemoteDirectory(const QString& path);
    void updateTransferProgress();
    void calculateTransferSpeed();
    QString formatFileSize(qint64 size);
    QString formatSpeed(qint64 bytesPerSecond);
    QString formatTimeRemaining(qint64 bytesRemaining, qint64 bytesPerSecond);
    void showTransferDialog(const TransferItem& item);
    void showPermissionsDialog(const QString& path);
    void showRenameDialog(const QString& path);
    void showNewDirectoryDialog();
    void handleDropFiles(const QMimeData* mimeData);
    void startNextTransfer();
    void cancelAllTransfers();

    // SFTP client
    SftpClient* m_sftpClient;
    
    // UI components
    QSplitter* m_mainSplitter;
    
    // Local file view
    QTreeView* m_localView;
    SftpModel* m_localModel;
    QLineEdit* m_localPathEdit;
    QLabel* m_localStatusLabel;
    
    // Remote file view
    QTreeView* m_remoteView;
    SftpModel* m_remoteModel;
    QLineEdit* m_remotePathEdit;
    QLabel* m_remoteStatusLabel;
    
    // Transfer queue
    QListView* m_transferQueueView;
    QStandardItemModel* m_transferQueueModel;
    QToolBar* m_transferToolBar;
    QProgressBar* m_transferProgressBar;
    QLabel* m_transferSpeedLabel;
    QLabel* m_transferTimeLabel;
    
    // Toolbar
    QToolBar* m_toolBar;
    QAction* m_uploadAction;
    QAction* m_downloadAction;
    QAction* m_deleteAction;
    QAction* m_renameAction;
    QAction* m_newDirAction;
    QAction* m_refreshAction;
    QAction* m_permissionsAction;
    
    // Status bar
    QStatusBar* m_statusBar;
    QLabel* m_statusLabel;
    
    // State
    QString m_currentLocalPath;
    QString m_currentRemotePath;
    QList<TransferItem> m_transferQueue;
    TransferItem* m_currentTransfer = nullptr;
    bool m_isTransferring = false;
    qint64 m_totalTransferSize = 0;
    qint64 m_totalTransferred = 0;
    QTimer* m_speedTimer;
    qint64 m_lastBytesTransferred = 0;
    qint64 m_currentSpeed = 0;
    
    // Drag and drop
    bool m_isDragTarget = false;
};

#endif // SFTP_WIDGET_H
