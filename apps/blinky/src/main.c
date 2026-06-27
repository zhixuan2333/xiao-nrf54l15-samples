/*
 * LED blink for the Seeed XIAO nRF54L15.
 *
 * Toggles the board's user LED (the `led0` devicetree alias, defined by the
 * xiao_nrf54l15 board) once a second and logs each toggle to the console.
 */
#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/sys/printk.h>

#define BLINK_PERIOD_MS 1000

/* led0 alias is provided by the xiao_nrf54l15 board devicetree. */
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);

int main(void)
{
	if (!gpio_is_ready_dt(&led)) {
		printk("error: LED device %s not ready\n", led.port->name);
		return -1;
	}

	if (gpio_pin_configure_dt(&led, GPIO_OUTPUT_ACTIVE) < 0) {
		printk("error: cannot configure LED pin\n");
		return -1;
	}

	printk("Blinky on %s — LED on pin %d\n", CONFIG_BOARD_TARGET, led.pin);

	while (1) {
		gpio_pin_toggle_dt(&led);
		k_msleep(BLINK_PERIOD_MS);
	}
	return 0;
}
