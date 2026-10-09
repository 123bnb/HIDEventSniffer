# HIDEventSniffer —— 蓝牙翻页器 HID 事件抓取诊断（仅注入 SpringBoard）
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES := SpringBoard
THEOS_PACKAGE_SCHEME := roothide

DEBUG = 0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HIDEventSniffer
HIDEventSniffer_FILES = Tweak.xm
HIDEventSniffer_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
HIDEventSniffer_LDFLAGS = -Wl,-undefined,dynamic_lookup
HIDEventSniffer_FRAMEWORKS = Foundation UIKit IOKit
HIDEventSniffer_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

# 强制 OpenStep 格式 Filter，只注入 SpringBoard（对齐左滑返回可注入写法）
before-package::
	printf '{ Filter = { Bundles = ( "com.apple.springboard"); }; }\n' > "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/HIDEventSniffer.plist"
