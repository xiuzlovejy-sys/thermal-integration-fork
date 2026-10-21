export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CLThermalSim
CLThermalSim_FILES = CLThermalSimTweak.x
CLThermalSim_CFLAGS = -fobjc-arc
CLThermalSim_FRAMEWORKS = Foundation IOKit
CLThermalSim_LDFLAGS = -L$(THEOS)/vendor/lib -lroothide

include $(THEOS_MAKE_PATH)/tweak.mk
