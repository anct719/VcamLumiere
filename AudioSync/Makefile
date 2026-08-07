export TARGET := iphone:clang:latest:15.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = SpringBoard com.apple.camera

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = audiosync

audiosync_FILES = src/Tweak.xm
audiosync_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable
audiosync_LDFLAGS = -framework AVFoundation -framework CoreMedia -framework CoreAudio -framework AudioToolbox -framework MediaToolbox -framework UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
