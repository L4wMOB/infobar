TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = InfoBarPrefs

InfoBarPrefs_FILES = IBPRootListController.m
InfoBarPrefs_FRAMEWORKS = UIKit
InfoBarPrefs_PRIVATE_FRAMEWORKS = Preferences
InfoBarPrefs_INSTALL_PATH = /Library/PreferenceBundles
InfoBarPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
