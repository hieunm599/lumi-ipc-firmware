################################################################################
#
# aic8800-openipc
#
################################################################################

AIC8800_OPENIPC_SITE = $(call github,openipc,aic8800,$(AIC8800_OPENIPC_VERSION))
# This revision contains USB support for AIC8800D80 (USB ID a69c:8d80).
AIC8800_OPENIPC_VERSION = 0e218ed686ee04a3006bb142ca70450dfa72f4d2
AIC8800_OPENIPC_MODULE_SUBDIRS = .
AIC8800_OPENIPC_MODULE_MAKE_OPTS = \
	CONFIG_USE_FW_REQUEST=n \
	INSTALL_MOD_PATH=$(TARGET_DIR) \
	INSTALL_MOD_DIR=kernel/drivers/net/wireless/aic8800

AIC8800_OPENIPC_LICENSE = GPL-2.0

$(eval $(kernel-module))
$(eval $(generic-package))
