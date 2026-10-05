# This SDK has the dual-sensor fsync ABI missing from OpenIPC/openingenic.
# Keep its ISP archive, headers and both sensors on the same upstream revision.
LUMI_T23_DUAL_SDK_VERSION = 343ae306c99b50f1c79e038a7ef0aee8af6c1c2e
LUMI_T23_DUAL_SDK_SITE = $(call github,thingino,ingenic-sdk,$(LUMI_T23_DUAL_SDK_VERSION))
LUMI_T23_DUAL_SDK_LICENSE = GPL-2.0+, PROPRIETARY
LUMI_T23_DUAL_SDK_LICENSE_FILES = LICENSE
LUMI_T23_DUAL_SDK_MODULE_MAKE_OPTS = \
	SOC_FAMILY=t23 KERNEL_VERSION=3.10.14 CONFIG_MULTI_SENSOR=1 \
	SENSOR_1_MODEL=os02n10s0 SENSOR_2_MODEL=os02n10s1 \
	CONFIG_INGENIC_ISP=y CONFIG_INGENIC_SENSOR=y CONFIG_INGENIC_AUDIO=y \
	CONFIG_INGENIC_GPIO_USERKEYS=n CONFIG_INGENIC_JZ_AES=n \
	CONFIG_INGENIC_TCU_ALLOC=n CONFIG_INGENIC_PWM=n CONFIG_INGENIC_MOTOR=n \
	EXTRA_CFLAGS=-DCONFIG_KERNEL_3_10 INSTALL_MOD_DIR=ingenic

define LUMI_T23_DUAL_SDK_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 644 $(@D)/sensor-iq/t23/os02n10.bin $(TARGET_DIR)/etc/sensor/os02n10-t23.bin
	mkdir -p $(TARGET_DIR)/usr/share/sensor
	ln -sf ../../../etc/sensor/os02n10-t23.bin $(TARGET_DIR)/usr/share/sensor/os02n10-t23.bin
endef

$(eval $(kernel-module))
$(eval $(generic-package))
