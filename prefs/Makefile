TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DecoyLockPrefs
DecoyLockPrefs_INSTALL_PATH = /Library/PreferenceBundles

DecoyLockPrefs_FILES = DLRootListController.m
DecoyLockPrefs_CFLAGS = -fobjc-arc -Wno-unused-function
DecoyLockPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
DecoyLockPrefs_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 Preferences || true"
