# HIDEventSniffer 设置页子工程（生成 HIDEventSniffer.bundle）
TARGET := iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME := roothide
ARCHS = arm64 arm64e

include $(THEOS_MAKE_PATH)/common.mk

BUNDLE_NAME = HIDEventSniffer

HIDEventSniffer_FILES = RootListController.m
HIDEventSniffer_FRAMEWORKS = UIKit
HIDEventSniffer_PRIVATE_FRAMEWORKS = Preferences
HIDEventSniffer_INSTALL_PATH = /Library/PreferenceBundles
HIDEventSniffer_CFLAGS = -fobjc-arc -Wno-arc-performSelector-leaks
# 允许未定义符号在运行时解析（CFNotificationCenterGetDarwinCenter 是私有符号，运行时存在）
HIDEventSniffer_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
