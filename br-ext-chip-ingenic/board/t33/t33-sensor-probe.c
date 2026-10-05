#include <stdio.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

#include <imp/imp_isp.h>

/* Minimal single-sensor version of the SDK sample_system_init() sequence. */
static volatile sig_atomic_t stopping;

static void stop_probe(int signal_number)
{
	(void)signal_number;
	stopping = 1;
}

int main(void)
{
	IMPSensorInfo sensor;
	IMPISPDefaultBinAttr bin;
	int ret;
	int sensor_added = 0;
	int sensor_enabled = 0;
	int isp_open = 0;

	memset(&sensor, 0, sizeof(sensor));
	strncpy(sensor.name, "sc4336", sizeof(sensor.name) - 1);
	sensor.cbus_type = TX_SENSOR_CONTROL_INTERFACE_I2C;
	strncpy(sensor.i2c.type, "sc4336", sizeof(sensor.i2c.type) - 1);
	sensor.i2c.addr = 0x30;
	sensor.i2c.i2c_adapter_id = 0;
	sensor.rst_gpio = GPIO_PA(20);
	sensor.pwdn_gpio = -1;
	sensor.power_gpio = -1;
	/* Match the SDK sample's single-sensor input-switch configuration. */
	sensor.switch_gpio = GPIO_PA(25);
	sensor.switch_gpio_state = 0;
	sensor.sensor_id = 0;
	sensor.video_interface = IMPISP_SENSOR_VI_MIPI_CSI0;
	sensor.mclk = IMPISP_SENSOR_MCLK0;
	sensor.default_boot = 0;
	sensor.fps.num = 15;
	sensor.fps.den = 1;
	signal(SIGINT, stop_probe);
	signal(SIGTERM, stop_probe);

	printf("T33gs SC4336 probe: I2C0 address 0x30, reset GPIO %d\n", sensor.rst_gpio);
	ret = IMP_ISP_Open();
	if (ret < 0) {
		printf("IMP_ISP_Open failed: %d\n", ret);
		return 1;
	}
	isp_open = 1;

	/* These PRJ008 bins must be registered before AddSensor on this SDK. */
	memset(&bin, 0, sizeof(bin));
	bin.mode = IMPISP_BIN_MODE_DAY;
	strncpy(bin.bname, "/etc/sensor/sc4336-PRJ008-day.bin", sizeof(bin.bname) - 1);
	ret = IMP_ISP_SetDefaultBinPath(IMPVI_MAIN, &bin);
	if (ret < 0) {
		printf("IMP_ISP_SetDefaultBinPath(day) failed: %d\n", ret);
		goto out;
	}
	bin.mode = IMPISP_BIN_MODE_NIGHT;
	strncpy(bin.bname, "/etc/sensor/sc4336-PRJ008-night.bin", sizeof(bin.bname) - 1);
	ret = IMP_ISP_SetDefaultBinPath(IMPVI_MAIN, &bin);
	if (ret < 0) {
		printf("IMP_ISP_SetDefaultBinPath(night) failed: %d\n", ret);
		goto out;
	}

	ret = IMP_ISP_AddSensor(IMPVI_MAIN, &sensor);
	if (ret < 0) {
		printf("IMP_ISP_AddSensor failed: %d\n", ret);
		goto out;
	}
	sensor_added = 1;
	printf("IMP_ISP_AddSensor succeeded\n");

	ret = IMP_ISP_EnableSensor(IMPVI_MAIN, &sensor);
	if (ret < 0) {
		printf("IMP_ISP_EnableSensor failed: %d\n", ret);
		goto out;
	}
	sensor_enabled = 1;
	printf("IMP_ISP_EnableSensor succeeded; sensor remains active for inspection\n");
	printf("Inspect dmesg and /sys/bus/i2c/devices; stop this utility with Ctrl-C.\n");
	while (!stopping)
		sleep(60);
	ret = 0;

out:
	if (sensor_enabled)
		IMP_ISP_DisableSensor(IMPVI_MAIN);
	if (sensor_added)
		IMP_ISP_DelSensor(IMPVI_MAIN, &sensor);
	if (isp_open)
		IMP_ISP_Close();
	return ret < 0 ? 1 : 0;
}
