# xiao-nrf54l15-samples

Two minimal **nRF Connect SDK (v3.3.0)** samples for the **Seeed XIAO nRF54L15**,
ready to build, flash and debug from a **GitHub Codespace** using the prebuilt
[`ncs-container`](https://github.com/zhixuan2333/ncs-container) dev container.

| Sample | What it does |
|---|---|
| [`apps/hello_world`](apps/hello_world) | Prints `Hello World` + a 1 Hz heartbeat to the serial console |
| [`apps/blinky`](apps/blinky) | Toggles the board LED (`led0`) once a second |

Board target: **`xiao_nrf54l15/nrf54l15/cpuapp`**

---

## Quick start (GitHub Codespaces)

1. **Open in a Codespace** — *Code → Codespaces → Create*. It pulls the prebuilt
   image with NCS already baked in (no `west update` wait). `$BOARD` is preset to
   `xiao_nrf54l15/nrf54l15/cpuapp`.

2. **Build** (inside the Codespace):
   ```bash
   west build -b $BOARD apps/hello_world     # or apps/blinky
   ```

3. **Connect the board** (on your **local** machine, XIAO + CMSIS-DAP probe plugged in):
   ```bash
   ./scripts/host-bridge.sh <codespace-name>
   ```
   This runs OpenOCD (`target/nordic/nrf54l.cfg`) + a serial bridge locally and
   reverse-tunnels them into the Codespace. Find the name with `gh codespace list`.
   Needs `gh`, `openocd`, `socat` locally — see the [ncs-container README](https://github.com/zhixuan2333/ncs-container#readme).

4. **Flash / serial / debug** (inside the Codespace):
   ```bash
   ./scripts/flash.sh        # flash build/zephyr/zephyr.elf via OpenOCD
   ./scripts/serial.sh       # watch the console (Hello World / blink logs)
   ./scripts/debug.sh        # interactive arm-zephyr-eabi-gdb
   ```

> nRF54L OpenOCD flashing needs a recent OpenOCD with the nRF54 NVM/RRAM driver.
> Check `openocd --version` on your local machine; install a current build if older.

---

## Build locally (without Codespaces)

Anywhere Docker runs:

```bash
docker run --rm -it -v "$PWD":/work -w /work \
  ghcr.io/zhixuan2333/ncs-container:v3.3.0 \
  bash -lc 'west build -b xiao_nrf54l15/nrf54l15/cpuapp apps/blinky'
```

## CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) compiles both samples
for the XIAO nRF54L15 in the same prebuilt image and uploads the `.elf/.hex/.bin`
as artifacts — so every push verifies the toolchain + board + sources still line up.

---

## Layout

```
.devcontainer/      # devcontainer.json -> ghcr.io/zhixuan2333/ncs-container:v3.3.0
apps/
  hello_world/      # printk hello + heartbeat
  blinky/           # led0 toggle
scripts/            # host-bridge (local) + flash/serial/debug (codespace)
.github/workflows/  # build both samples in CI
```
