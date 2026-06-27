/*
 * Hello World for the Seeed XIAO nRF54L15.
 *
 * Prints once on boot and then a heartbeat every second so you can confirm the
 * forwarded serial console (./scripts/serial.sh) is alive.
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>

int main(void)
{
	uint32_t count = 0;

	printk("Hello World from %s!\n", CONFIG_BOARD_TARGET);

	while (1) {
		printk("alive: %u\n", count++);
		k_msleep(1000);
	}
	return 0;
}
