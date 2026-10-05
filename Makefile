TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DecoyLock

DecoyLock_FILES = Tweak.x DLCommon.m DLDecoyController.m
DecoyLock_CFLAGS = -fobjc-arc -Wno-unused-function
DecoyLock_LDFLAGS = -Wl,-undefined,dynamic_lookup
DecoyLock_FRAMEWORKS = UIKit CoreGraphics QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
