# HIDEventSniffer —— 蓝牙翻页器按键抓取（v1.0.3 用户方案版）
# 架构：
#   - Tweak.xm 注入 Preferences 进程（Filter=com.apple.Preferences），hook sendEvent
#     捕获蓝牙键盘/触摸事件，写入 Preferences 沙盒 Documents/HIDEventSniffer.log
#   - Preferences/HIDEventSniffer.bundle 设置页：实时显示日志（自动刷新+手动刷新+清空）
#   - 只注入 Preferences 一个进程，不碰 SpringBoard，安全模式风险归零
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES := Preferences
THEOS_PACKAGE_SCHEME := roothide
PACKAGE_VERSION := 1.0.10

DEBUG = 0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HIDEventSniffer

HIDEventSniffer_FILES = Tweak.xm
HIDEventSniffer_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -Wno-arc-performSelector-leaks
HIDEventSniffer_LDFLAGS = -Wl,-undefined,dynamic_lookup
HIDEventSniffer_FRAMEWORKS = Foundation UIKit
HIDEventSniffer_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

# ---------- 设置页 ----------
SUBPROJECTS += Preferences

include $(THEOS_MAKE_PATH)/aggregate.mk

# ---------- 强制 OpenStep 格式注入 Filter（对齐左滑返回可注入写法）----------
before-package::
	printf '{ Filter = { Bundles = ( "com.apple.Preferences"); }; }\n' > "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/HIDEventSniffer.plist"
