#!/bin/sh
# 抓料机 (qt-app-grabber) Kiosk 启动脚本 - weston kiosk-shell 开机自启入口
# S49weston 启动 weston 后以 nohup 方式调用本脚本; 完整环境变量与 run-grabber.sh 对齐。
APP_DIR="/data/local/tmp/qt-rust-demo"
export LD_LIBRARY_PATH="$APP_DIR/lib:/usr/lib"
export QT_PLUGIN_PATH="$APP_DIR/plugins"
export XDG_RUNTIME_DIR=/var/run
export WAYLAND_DISPLAY=wayland-0
export WAYLAND_WAIT=1
export QT_QPA_PLATFORM=wayland
export QML2_IMPORT_PATH="$APP_DIR/qml_modules"
export QT_QUICK_BACKEND=software
export FONTCONFIG_FILE="$APP_DIR/fonts/fonts.conf"
export FONTCONFIG_PATH="$APP_DIR/fonts"
export XDG_CONFIG_HOME=/tmp/qt-app-config
mkdir -p /tmp/qt-app-config
cd "$APP_DIR"
exec "$APP_DIR/qt-app-grabber" "$@"
