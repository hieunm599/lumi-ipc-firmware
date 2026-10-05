# Lumi Camera external tree. Loaded after GENERAL (Makefile passes
# BR2_EXTERNAL=general:lumi for boards under lumi/configs), so GENERAL's
# OPENIPC_* variables and EXTERNAL_VENDOR are already defined here.

LUMI_BOARD_DIR = $(BR2_EXTERNAL_LUMI_PATH)/board

include $(sort $(wildcard $(BR2_EXTERNAL_LUMI_PATH)/package/*/*.mk))
