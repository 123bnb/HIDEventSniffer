# HIDEventSniffer —— 蓝牙翻页器事件抓取诊断
# 两个注入目标：
#   HIDEventSniffer    -> 仅注入 SpringBoard（自建 HID 监听 + 统一写日志 + 收 App 转发）
#   HIDEventSnifferApp -> 注入所有 App（UIKit Filter，捕获方向键/点击/触摸并转发）
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES := SpringBoard
THEOS_PACKAGE_SCHEME := roothide
PACKAGE_VERSION := 1.0.2

DEBUG = 0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HIDEventSniffer HIDEventSnifferApp

HIDEventSniffer_FILES = TweakSpringBoard.xm
HIDEventSniffer_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
HIDEventSniffer_LDFLAGS = -Wl,-undefined,dynamic_lookup
HIDEventSniffer_FRAMEWORKS = Foundation UIKit IOKit
HIDEventSniffer_LIBRARIES = substrate

HIDEventSnifferApp_FILES = TweakApp.xm
HIDEventSnifferApp_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
HIDEventSnifferApp_LDFLAGS = -Wl,-undefined,dynamic_lookup
HIDEventSnifferApp_FRAMEWORKS = Foundation UIKit
HIDEventSnifferApp_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

# 强制 OpenStep 格式 Filter（对齐左滑返回可注入写法）
before-package::
	printf '{ Filter = { Bundles = ( "com.apple.springboard"); }; }\n' > "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/HIDEventSniffer.plist"
	printf '{ Filter = { Bundles = ( "com.apple.UIKit"); }; }\n' > "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/HIDEventSnifferApp.plist"
