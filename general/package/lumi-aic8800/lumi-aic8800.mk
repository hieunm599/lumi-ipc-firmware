LUMI_AIC8800_VERSION = 96cd509a9b6282d4f55adf2b394801ae9ae22599
LUMI_AIC8800_SITE = $(call github,gtxaspec,aic8800-wifi,$(LUMI_AIC8800_VERSION))
LUMI_AIC8800_LICENSE = GPL-2.0, PROPRIETARY
LUMI_AIC8800_MODULE_SUBDIRS = USB/driver_fw/drivers/aic8800
# Vendor file loading uses /lib/firmware and appends aic8800DC for this USB ID.
LUMI_AIC8800_MODULE_MAKE_OPTS = \
	CONFIG_PLATFORM_UBUNTU=n CONFIG_USE_FW_REQUEST=n \
	CONFIG_USE_WIRELESS_EXT=n CONFIG_RWNX_RADAR=n \
	CONFIG_AIC_CHIP_8800DC=y INSTALL_MOD_DIR=wireless

define LUMI_AIC8800_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/lib/firmware/aic8800DC
	$(INSTALL) -m 644 $(@D)/USB/driver_fw/fw/aic8800DC/* $(TARGET_DIR)/lib/firmware/aic8800DC/
endef

$(eval $(kernel-module))
$(eval $(generic-package))
