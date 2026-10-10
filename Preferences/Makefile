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

include $(THEOS_MAKE_PATH)/bundle.mk
