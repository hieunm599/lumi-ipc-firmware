################################################################################
#
# ipctool
#
################################################################################

IPCTOOL_SITE = $(call github,openipc,ipctool,$(IPCTOOL_VERSION))
IPCTOOL_VERSION = HEAD

IPCTOOL_LICENSE = MIT
IPCTOOL_LICENSE_FILES = LICENSE
IPCTOOL_INSTALL_STAGING = YES

IPCTOOL_CONF_OPTS += -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release -DSKIP_VERSION=ON
IPCTOOL_MAKE_OPTS += VERBOSE=1

define IPCTOOL_INSTALL_STAGING_CMDS
	$(INSTALL) -m 755 -t $(STAGING_DIR)/usr/lib $(@D)/libipchw.a
endef

define IPCTOOL_INSTALL_TARGET_CMDS
	$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/bin
	$(INSTALL) -m 755 -t $(TARGET_DIR)/usr/bin $(@D)/ipcinfo
endef

# The upstream release binary is a static MIPS32r2/musl build. Embed it on
# little-endian MIPS targets so ipctool works without fetching a plugin at
# runtime. Keep the other architectures on the existing download-on-demand path.
ifeq ($(BR2_mipsel),y)
define IPCTOOL_INSTALL_MIPS32_CMDS
	$(INSTALL) -m 755 -D $(IPCTOOL_PKGDIR)/files/ipctool-mips32 $(TARGET_DIR)/usr/bin/ipctool
endef
IPCTOOL_POST_INSTALL_TARGET_HOOKS += IPCTOOL_INSTALL_MIPS32_CMDS
endif

$(eval $(cmake-package))
