#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <imp/imp_framesource.h>
#include <imp/imp_isp.h>
#include <imp/imp_system.h>

#define FRAME_WIDTH 2560
#define FRAME_HEIGHT 1440
#define FRAME_COUNT 3

static int check(const char *name, int ret)
{
	printf("%s: %d\n", name, ret);
	return ret < 0 ? -1 : 0;
}

int main(void)
{
	IMPSensorInfo sensor;
	IMPISPDefaultBinAttr bin;
	IMPFSChnAttr chn;
	IMPFrameInfo *frame = NULL;
	unsigned int n;
	int ret;
	int isp_open = 0;
	int sensor_added = 0;
	int sensor_enabled = 0;
	int system_ready = 0;
	int tuning_enabled = 0;
	int channel_created = 0;
	int channel_enabled = 0;

	memset(&sensor, 0, sizeof(sensor));
	strncpy(sensor.name, "sc4336", sizeof(sensor.name) - 1);
	sensor.cbus_type = TX_SENSOR_CONTROL_INTERFACE_I2C;
	strncpy(sensor.i2c.type, "sc4336", sizeof(sensor.i2c.type) - 1);
	sensor.i2c.addr = 0x30;
	sensor.i2c.i2c_adapter_id = 0;
	sensor.rst_gpio = GPIO_PA(20);
	sensor.pwdn_gpio = -1;
	sensor.power_gpio = -1;
	sensor.switch_gpio = GPIO_PA(25);
	sensor.switch_gpio_state = 0;
	sensor.sensor_id = 0;
	sensor.video_interface = IMPISP_SENSOR_VI_MIPI_CSI0;
	sensor.mclk = IMPISP_SENSOR_MCLK0;
	sensor.default_boot = 0;
	sensor.fps.num = 15;
	sensor.fps.den = 1;

	ret = IMP_ISP_Open();
	if (check("IMP_ISP_Open", ret) < 0)
		goto out;
	isp_open = 1;

	memset(&bin, 0, sizeof(bin));
	bin.mode = IMPISP_BIN_MODE_DAY;
	strncpy(bin.bname, "/etc/sensor/sc4336-PRJ008-day.bin", sizeof(bin.bname) - 1);
	ret = IMP_ISP_SetDefaultBinPath(IMPVI_MAIN, &bin);
	if (check("IMP_ISP_SetDefaultBinPath(day)", ret) < 0)
		goto out;
	bin.mode = IMPISP_BIN_MODE_NIGHT;
	strncpy(bin.bname, "/etc/sensor/sc4336-PRJ008-night.bin", sizeof(bin.bname) - 1);
	ret = IMP_ISP_SetDefaultBinPath(IMPVI_MAIN, &bin);
	if (check("IMP_ISP_SetDefaultBinPath(night)", ret) < 0)
		goto out;

	ret = IMP_ISP_AddSensor(IMPVI_MAIN, &sensor);
	if (check("IMP_ISP_AddSensor", ret) < 0)
		goto out;
	sensor_added = 1;

	ret = IMP_ISP_EnableSensor(IMPVI_MAIN, &sensor);
	if (check("IMP_ISP_EnableSensor", ret) < 0)
		goto out;
	sensor_enabled = 1;

	ret = IMP_System_Init();
	if (check("IMP_System_Init", ret) < 0)
		goto out;
	system_ready = 1;

	ret = IMP_ISP_EnableTuning();
	if (check("IMP_ISP_EnableTuning", ret) < 0)
		goto out;
	tuning_enabled = 1;

	memset(&chn, 0, sizeof(chn));
	chn.picWidth = FRAME_WIDTH;
	chn.picHeight = FRAME_HEIGHT;
	chn.pixFmt = PIX_FMT_NV12;
	chn.outFrmRateNum = 15;
	chn.outFrmRateDen = 1;
	chn.nrVBs = 1;
	chn.type = FS_PHY_CHANNEL;
	ret = IMP_FrameSource_CreateChn(0, &chn);
	if (check("IMP_FrameSource_CreateChn", ret) < 0)
		goto out;
	channel_created = 1;

	ret = IMP_FrameSource_EnableChn(0);
	if (check("IMP_FrameSource_EnableChn", ret) < 0)
		goto out;
	channel_enabled = 1;
	ret = IMP_FrameSource_SetFrameDepth(0, 1);
	if (check("IMP_FrameSource_SetFrameDepth", ret) < 0)
		goto out;

	for (n = 0; n < FRAME_COUNT; n++) {
		uint8_t *data;
		uint32_t offsets[5];
		uint32_t i;
		uint32_t nonzero = 0;
		uint64_t checksum = 1469598103934665603ULL;

		frame = NULL;
		ret = IMP_FrameSource_GetFrame(0, &frame);
		if (check("IMP_FrameSource_GetFrame", ret) < 0 || !frame) {
			if (ret >= 0) {
				fprintf(stderr, "GetFrame returned a null frame\n");
				ret = -1;
			}
			goto out;
		}

		data = (uint8_t *)(uintptr_t)frame->virAddr;
		printf("frame[%u] metadata: info=%p %" PRIu32 "x%" PRIu32
		       " fmt=%" PRIu32 " size=%" PRIu32 " phy=0x%08" PRIx32
		       " vir=0x%08" PRIx32 " direct=0x%08" PRIx32 "\n",
		       n, (void *)frame, frame->width, frame->height, frame->pixfmt,
		       frame->size, frame->phyAddr, frame->virAddr,
		       frame->direct_phyAddr);
		fflush(stdout);
		if (!data || !frame->size || frame->size > 32 * 1024 * 1024) {
			fprintf(stderr, "frame has no virtual address or data\n");
			ret = -1;
		} else {
			offsets[0] = 0;
			offsets[1] = frame->size / 4;
			offsets[2] = frame->size / 2;
			offsets[3] = (frame->size * 3) / 4;
			offsets[4] = frame->size - 1;
			for (i = 0; i < 5; i++) {
				uint8_t value = data[offsets[i]];
				printf("  sample[%" PRIu32 "]=0x%02x\n", offsets[i], value);
				nonzero += value != 0;
				checksum = (checksum ^ value) * 1099511628211ULL;
			}
			printf("frame[%u]: nonzero_samples=%" PRIu32 "/5 hash=%016" PRIx64 "\n",
			       n, nonzero, checksum);
			fflush(stdout);
			if (nonzero == 0)
				ret = -1;
		}

		if (IMP_FrameSource_ReleaseFrame(0, frame) < 0) {
			fprintf(stderr, "IMP_FrameSource_ReleaseFrame failed\n");
			ret = -1;
		}
		frame = NULL;
		if (ret < 0)
			goto out;
	}
	ret = 0;

out:
	if (frame)
		IMP_FrameSource_ReleaseFrame(0, frame);
	if (channel_enabled)
		IMP_FrameSource_DisableChn(0);
	if (channel_created)
		IMP_FrameSource_DestroyChn(0);
	if (tuning_enabled)
		IMP_ISP_DisableTuning();
	if (system_ready)
		IMP_System_Exit();
	if (sensor_enabled)
		IMP_ISP_DisableSensor(IMPVI_MAIN);
	if (sensor_added)
		IMP_ISP_DelSensor(IMPVI_MAIN, &sensor);
	if (isp_open)
		IMP_ISP_Close();
	return ret < 0 ? 1 : 0;
}
