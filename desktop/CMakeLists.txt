cmake_minimum_required(VERSION 3.16)
project(BlueSSH VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

# Find required packages
find_package(Qt6 REQUIRED COMPONENTS Core Widgets Network Sql Gui)
find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBSSH2 REQUIRED libssh2)
pkg_check_modules(LIBVTERM REQUIRED vterm)
pkg_check_modules(OPENSSL REQUIRED openssl)
pkg_check_modules(ZLIB REQUIRED zlib)
pkg_check_modules(ZSTD REQUIRED libzstd)

# Source files
set(SOURCES
    src/main.cpp
    src/core/SshEngine.cpp
    src/core/SshSession.cpp
    src/core/SftpClient.cpp
    src/core/KeyManager.cpp
    src/core/KnownHosts.cpp
    src/core/PortForwarding.cpp
    src/core/SessionManager.cpp
    src/core/RecordingManager.cpp
    src/core/CompressionManager.cpp
    src/ui/MainWindow.cpp
    src/ui/TerminalWidget.cpp
    src/ui/SftpWidget.cpp
    src/ui/HostProfileDialog.cpp
    src/ui/SettingsDialog.cpp
    src/ui/PortForwardingDialog.cpp
    src/ui/KeyManagementDialog.cpp
    src/ui/SessionTab.cpp
    src/ui/SearchBar.cpp
    src/models/HostProfile.cpp
    src/models/AppSettings.cpp
    src/utils/CryptoUtils.cpp
    src/utils/FileUtils.cpp
    src/utils/ConfigManager.cpp
)

set(HEADERS
    src/core/SshEngine.h
    src/core/SshSession.h
    src/core/SftpClient.h
    src/core/KeyManager.h
    src/core/KnownHosts.h
    src/core/PortForwarding.h
    src/core/SessionManager.h
    src/core/RecordingManager.h
    src/core/CompressionManager.h
    src/ui/MainWindow.h
    src/ui/TerminalWidget.h
    src/ui/SftpWidget.h
    src/ui/HostProfileDialog.h
    src/ui/SettingsDialog.h
    src/ui/PortForwardingDialog.h
    src/ui/KeyManagementDialog.h
    src/ui/SessionTab.h
    src/ui/SearchBar.h
    src/models/HostProfile.h
    src/models/AppSettings.h
    src/utils/CryptoUtils.h
    src/utils/FileUtils.h
    src/utils/ConfigManager.h
)

# Create executable
add_executable(bluessh ${SOURCES} ${HEADERS})

# Link libraries
target_link_libraries(bluessh PRIVATE
    Qt6::Core
    Qt6::Widgets
    Qt6::Network
    Qt6::Sql
    Qt6::Gui
    ${LIBSSH2_LIBRARIES}
    ${LIBVTERM_LIBRARIES}
    ${OPENSSL_LIBRARIES}
    ${ZLIB_LIBRARIES}
    ${ZSTD_LIBRARIES}
)

# Include directories
target_include_directories(bluessh PRIVATE
    ${LIBSSH2_INCLUDE_DIRS}
    ${LIBVTERM_INCLUDE_DIRS}
    ${OPENSSL_INCLUDE_DIRS}
    ${ZLIB_INCLUDE_DIRS}
    ${ZSTD_INCLUDE_DIRS}
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# Compiler flags
target_compile_options(bluessh PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -O2
)

# Install
install(TARGETS bluessh DESTINATION bin)

# CPack configuration
set(CPACK_PACKAGE_NAME "BlueSSH")
set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION})
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "High-performance SSH client")
set(CPACK_GENERATOR "DEB;TGZ")
set(CPACK_DEBIAN_PACKAGE_DEPENDS "libssh2-1, libvterm0, libssl3, zlib1g, libzstd1, libqt6core6, libqt6widgets6, libqt6network6, libqt6sql6, libqt6gui6")
include(CPack)
