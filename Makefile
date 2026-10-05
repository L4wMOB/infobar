TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME ?= rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = InfoBar

InfoBar_FILES = Tweak.x $(wildcard Sources/*.m)
InfoBar_CFLAGS = -fobjc-arc -ISources -Wno-deprecated-declarations
InfoBar_FRAMEWORKS = UIKit Foundation CoreFoundation QuartzCore IOKit

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += infobarprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
