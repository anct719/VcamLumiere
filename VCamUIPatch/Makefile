export TARGET := iphone:clang:latest:15.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = vcamui

vcamui_FILES = src/Tweak.xm
vcamui_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable -Wno-arc-performSelector-leaks
vcamui_LDFLAGS = -framework UIKit -framework AVFoundation -framework PhotosUI

include $(THEOS_MAKE_PATH)/tweak.mk
