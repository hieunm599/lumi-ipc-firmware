################################################################################
#
# lumi-osdrv-t33
#
################################################################################

LUMI_OSDRV_T33_VERSION = 1.0.0
LUMI_OSDRV_T33_DEPENDENCIES = linux

LUMI_OSDRV_T33_SOC_PROJECT = $(call qstrip,$(BR2_LUMI_T33_SOC_PROJECT))
ifeq ($(LUMI_OSDRV_T33_SOC_PROJECT),)
LUMI_OSDRV_T33_SOC_PROJECT = PRJ008
endif

LUMI_OSDRV_T33_SENSOR = $(call qstrip,$(or $(BR2_OPENIPC_SNS_MODEL),$(BR2_LUMI_T33_SNS_MODEL),sc4336))
LUMI_OSDRV_T33_WIFI_PWR_GPIO = $(call qstrip,$(BR2_LUMI_T33_WIFI_PWR_GPIO))
LUMI_OSDRV_T33_IRCUT_PIN_A = $(call qstrip,$(BR2_LUMI_T33_IRCUT_PIN_A))
LUMI_OSDRV_T33_IRCUT_PIN_B = $(call qstrip,$(BR2_LUMI_T33_IRCUT_PIN_B))

# Staged SDK work directory inside build output
T33_SDK_WORK = $(BINARIES_DIR)/../t33-sdk
T33_TOOLCHAIN = $(T33_SDK_WORK)/toolchain/mips-gcc540-uclibc0.9.33.2-r3.3.7.mxu2.cve2/bin/mips-linux-uclibc-
T33_DRIVER_SRC = $(T33_SDK_WORK)/driver-source/drivers
T33_ISP_SRC = $(T33_DRIVER_SRC)/isp/tx-isp
T33_AUDIO_SRC = $(T33_DRIVER_SRC)/audio/oss3
T33_SENSOR_SRC = $(T33_DRIVER_SRC)/sensors/$(LUMI_OSDRV_T33_SENSOR)/$(LUMI_OSDRV_T33_SOC_PROJECT)

define LUMI_OSDRV_T33_BUILD_CMDS
	@echo "--- Building Lumi T33 OSDRV: SOC=$(LUMI_OSDRV_T33_SOC_PROJECT) SENSOR=$(LUMI_OSDRV_T33_SENSOR) ---"
	# Build TX-ISP module
	if [ -f "$(T33_ISP_SRC)/Makefile" ]; then \
		cp -f "$(T33_SDK_WORK)/lib$(LUMI_OSDRV_T33_SOC_PROJECT)-firmware-310-540.a" \
			"$(T33_ISP_SRC)/lib$(LUMI_OSDRV_T33_SOC_PROJECT)-firmware.a" 2>/dev/null || true; \
		$(MAKE) -C $(LINUX_DIR) ARCH=mips CROSS_COMPILE="$(T33_TOOLCHAIN)" \
			M="$(T33_ISP_SRC)" PWD="$(T33_ISP_SRC)" \
			CONFIG_SOC_$(LUMI_OSDRV_T33_SOC_PROJECT)=y CONFIG_KERNEL_3_10=y modules; \
	fi

	# Build Sensor module
	if [ -f "$(T33_SENSOR_SRC)/$(LUMI_OSDRV_T33_SENSOR).c" ]; then \
		$(MAKE) -C $(LINUX_DIR) ARCH=mips CROSS_COMPILE="$(T33_TOOLCHAIN)" \
			M="$(T33_DRIVER_SRC)/sensors/$(LUMI_OSDRV_T33_SENSOR)" \
			PWD="$(T33_DRIVER_SRC)/sensors/$(LUMI_OSDRV_T33_SENSOR)" \
			TASSADAR_ENV_KERNEL_DIR="$(LINUX_DIR)" \
			CONFIG_SOC_$(LUMI_OSDRV_T33_SOC_PROJECT)=y CONFIG_KERNEL_3_10=y modules; \
	fi

	# Build OSS3 Audio module
	if [ -f "$(T33_AUDIO_SRC)/Makefile" ]; then \
		$(MAKE) -C $(LINUX_DIR) ARCH=mips CROSS_COMPILE="$(T33_TOOLCHAIN)" \
			M="$(T33_AUDIO_SRC)" PWD="$(T33_AUDIO_SRC)" \
			CONFIG_SOC_$(LUMI_OSDRV_T33_SOC_PROJECT)=y CONFIG_KERNEL_3_10=y modules; \
	fi

	# Build SDK sensor & frame probes
	if [ -x "$(T33_TOOLCHAIN)gcc" ] && [ -f "$(T33_SDK_WORK)/vendor-media/include/imp/imp_isp.h" ]; then \
		"$(T33_TOOLCHAIN)gcc" -muclibc -march=mips32r2 -O2 -Wall \
			-I"$(T33_SDK_WORK)/vendor-media/include" \
			-L"$(T33_SDK_WORK)/vendor-media/lib" -L"$(T33_SDK_WORK)/vendor-media/sdk-lib" \
			-Wl,--dynamic-linker=/opt/ingenic-t33/lib/ld-uClibc-0.9.33.2.so \
			-Wl,--enable-new-dtags -Wl,-rpath,/opt/ingenic-t33/lib \
			-o $(@D)/t33-sensor-probe \
			$(BR2_EXTERNAL_LUMI_PATH)/board/t33gs-prj008/t33-sensor-probe.c -limp -lalog -lrt 2>/dev/null || true; \
		"$(T33_TOOLCHAIN)gcc" -muclibc -march=mips32r2 -O2 -Wall \
			-I"$(T33_SDK_WORK)/vendor-media/include" \
			-L"$(T33_SDK_WORK)/vendor-media/lib" -L"$(T33_SDK_WORK)/vendor-media/sdk-lib" \
			-Wl,--dynamic-linker=/opt/ingenic-t33/lib/ld-uClibc-0.9.33.2.so \
			-Wl,--enable-new-dtags -Wl,-rpath,/opt/ingenic-t33/lib \
			-o $(@D)/t33-frame-probe \
			$(BR2_EXTERNAL_LUMI_PATH)/board/t33gs-prj008/t33-frame-probe.c -limp -lalog -lrt 2>/dev/null || true; \
	fi
endef

define LUMI_OSDRV_T33_INSTALL_TARGET_CMDS
	# 1. Install kernel modules
	$(INSTALL) -m 755 -d $(TARGET_DIR)/lib/modules/3.10.14/ingenic
	[ -f "$(T33_ISP_SRC)/tx-isp-$(LUMI_OSDRV_T33_SOC_PROJECT).ko" ] && \
		$(INSTALL) -m 644 "$(T33_ISP_SRC)/tx-isp-$(LUMI_OSDRV_T33_SOC_PROJECT).ko" \
			$(TARGET_DIR)/lib/modules/3.10.14/ingenic/ || true
	[ -f "$(T33_DRIVER_SRC)/sensors/$(LUMI_OSDRV_T33_SENSOR)/sensor_$(LUMI_OSDRV_T33_SENSOR)_$(LUMI_OSDRV_T33_SOC_PROJECT).ko" ] && \
		$(INSTALL) -m 644 "$(T33_DRIVER_SRC)/sensors/$(LUMI_OSDRV_T33_SENSOR)/sensor_$(LUMI_OSDRV_T33_SENSOR)_$(LUMI_OSDRV_T33_SOC_PROJECT).ko" \
			$(TARGET_DIR)/lib/modules/3.10.14/ingenic/ || true
	[ -f "$(T33_AUDIO_SRC)/audio.ko" ] && \
		$(INSTALL) -m 644 "$(T33_AUDIO_SRC)/audio.ko" \
			$(TARGET_DIR)/lib/modules/3.10.14/ingenic/ || true

	# 2. Install ISP sensor tuning bins
	$(INSTALL) -m 755 -d $(TARGET_DIR)/etc/sensor
	for bin in $(T33_SDK_WORK)/sc4336-isp-bins/*.bin; do \
		[ -f "$$bin" ] && $(INSTALL) -m 644 "$$bin" $(TARGET_DIR)/etc/sensor/ || true; \
	done

	# 3. Install vendor media uClibc runtime and probe binaries
	$(INSTALL) -m 755 -d $(TARGET_DIR)/opt/ingenic-t33/lib
	if [ -d "$(T33_SDK_WORK)/vendor-media/lib" ]; then \
		cp -a $(T33_SDK_WORK)/vendor-media/lib/. $(TARGET_DIR)/opt/ingenic-t33/lib/; \
		python3 $(BR2_EXTERNAL_LUMI_PATH)/board/t33gs-prj008/fix-xsym-links.py $(TARGET_DIR)/opt/ingenic-t33/lib; \
	fi
	[ -f $(@D)/t33-sensor-probe ] && $(INSTALL) -m 755 $(@D)/t33-sensor-probe $(TARGET_DIR)/opt/ingenic-t33/ || true
	[ -f $(@D)/t33-frame-probe ] && $(INSTALL) -m 755 $(@D)/t33-frame-probe $(TARGET_DIR)/opt/ingenic-t33/ || true

	# 4. Generate hardware abstraction config (/etc/hardware.env)
	@echo "Generating $(TARGET_DIR)/etc/hardware.env..."
	@echo "# Auto-generated from Lumi Buildroot defconfig - DO NOT EDIT MANUALLY" > $(TARGET_DIR)/etc/hardware.env
	@echo "SOC_FAMILY=t33" >> $(TARGET_DIR)/etc/hardware.env
	@echo "SOC_PROJECT=$(LUMI_OSDRV_T33_SOC_PROJECT)" >> $(TARGET_DIR)/etc/hardware.env
	@echo "SENSOR_MODEL=$(LUMI_OSDRV_T33_SENSOR)" >> $(TARGET_DIR)/etc/hardware.env
	@echo "SENSOR_MODULE=sensor_$(LUMI_OSDRV_T33_SENSOR)_$(LUMI_OSDRV_T33_SOC_PROJECT).ko" >> $(TARGET_DIR)/etc/hardware.env
	@echo "ISP_MODULE=tx-isp-$(LUMI_OSDRV_T33_SOC_PROJECT).ko" >> $(TARGET_DIR)/etc/hardware.env
	@echo "WIFI_PWR_GPIO=$(LUMI_OSDRV_T33_WIFI_PWR_GPIO)" >> $(TARGET_DIR)/etc/hardware.env
	@echo "IRCUT_PIN_A=$(LUMI_OSDRV_T33_IRCUT_PIN_A)" >> $(TARGET_DIR)/etc/hardware.env
	@echo "IRCUT_PIN_B=$(LUMI_OSDRV_T33_IRCUT_PIN_B)" >> $(TARGET_DIR)/etc/hardware.env
endef

$(eval $(generic-package))
