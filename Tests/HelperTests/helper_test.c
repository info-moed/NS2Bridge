// End-to-end test of the game helper's virtual gamepads (Hooks/ns2rumble.c), no game or controller needed.
// Plays NS2 Bridge's side of the loopback protocol (docs/reference/helper-protocol.md) against the helper loaded
// into this process, with a fake SDL (fake_sdl.c) recording what the helper does. Run by scripts/helper-test.sh.
//
//   helper_test <path to ns2rumble.dylib>        built with -DFAKE_SDL3 or -DFAKE_SDL2
#include <arpa/inet.h>
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

typedef struct {
    int attached, detached, opened, closed;
    uint16_t product, nsensors, nbuttons, naxes;
    int16_t axes[8];
    uint32_t buttons;
    float accel[3], gyro[3];
    int sensor_events;
    void *userdata;
    void (*update)(void *);
    void *rumble;
} fake_state_t;
extern fake_state_t *fake_state(void);
extern void fake_rumble(uint16_t lo, uint16_t hi);
extern int SDL_PollEvent(void *event);          // from the fake SDL; the helper rewires this call to its wrapper

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { printf("FAIL: " __VA_ARGS__); printf("\n"); failures++; } } while (0)

static int sock;
static struct sockaddr_in helper;

/// Next packet with this magic from the helper (remembers the helper's address), or 0 bytes on timeout.
static ssize_t receive(const char *magic, uint8_t *buf, size_t len) {
    for (int tries = 0; tries < 50; tries++) {
        socklen_t sl = sizeof helper;
        ssize_t n = recvfrom(sock, buf, len, 0, (struct sockaddr *)&helper, &sl);
        if (n >= 4 && memcmp(buf, magic, 4) == 0) return n;
    }
    return 0;
}

static void put(uint8_t *p, const void *v, size_t n) { memcpy(p, v, n); }

static void send_state(void) {
    uint8_t p[6 + 52] = {'N', 'S', '2', 'V', 1, 1};
    uint8_t *e = p + 6;
    uint16_t product = 0x2069;
    uint32_t buttons = 1u << 0 | 1u << 11;                       // south, d-pad up
    int16_t axes[6] = {1000, -2000, 3000, -4000, -32768, 32767};
    float accel[3] = {0, 9.80665f, 1.8f}, gyro[3] = {0.1f, 0.2f, 0.3f};
    uint64_t us = 5000000;
    e[0] = 1; e[1] = 1;                                          // slot 1, motion valid
    put(e + 2, &product, 2); put(e + 4, &buttons, 4); put(e + 8, axes, 12);
    put(e + 20, accel, 12); put(e + 32, gyro, 12); put(e + 44, &us, 8);
    sendto(sock, p, sizeof p, 0, (struct sockaddr *)&helper, sizeof helper);
}

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: helper_test <ns2rumble.dylib>\n"); return 2; }
    sock = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in me = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    bind(sock, (struct sockaddr *)&me, sizeof me);
    socklen_t ml = sizeof me;
    getsockname(sock, (struct sockaddr *)&me, &ml);
    struct timeval tv = {.tv_sec = 0, .tv_usec = 100000};
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    char port[8];
    snprintf(port, sizeof port, "%u", ntohs(me.sin_port));
    setenv("NS2_BRIDGE_PORT", port, 1);                          // the helper talks to us, not to NS2 Bridge
    setenv("NS2_LAUNCHED", "1", 1);

    if (!dlopen(argv[1], RTLD_NOW)) { printf("FAIL: dlopen: %s\n", dlerror()); return 1; }
    uint8_t buf[256];
    CHECK(receive("NS2K", buf, sizeof buf) >= 8, "no keep-alive from the helper");
    fake_state_t *s = fake_state();

    // 1. A Bluetooth controller appears: the helper attaches a gamepad from the game's event call.
    send_state();
    usleep(100000);
    SDL_PollEvent(NULL);
    SDL_PollEvent(NULL);
    CHECK(s->attached == 1, "attached %d times, expected 1", s->attached);
    CHECK(s->product == 0x2069, "product %04X", s->product);
    CHECK(s->nbuttons == 16 && s->naxes == 6, "buttons %u axes %u", s->nbuttons, s->naxes);
    CHECK(s->axes[0] == 1000 && s->axes[1] == -2000 && s->axes[3] == -4000 && s->axes[4] == -32768 && s->axes[5] == 32767,
          "axes %d %d %d %d %d %d", s->axes[0], s->axes[1], s->axes[2], s->axes[3], s->axes[4], s->axes[5]);
    CHECK(s->buttons == (1u << 0 | 1u << 11), "buttons %04X", s->buttons);
#ifdef FAKE_SDL3
    CHECK(s->nsensors == 2, "sensors %u, expected 2 (SDL3 virtual sensors)", s->nsensors);
    CHECK(s->sensor_events >= 2 && fabsf(s->accel[1] - 9.80665f) < 1e-4f && fabsf(s->gyro[2] - 0.3f) < 1e-6f,
          "motion: %d events, accel y %.3f, gyro z %.3f", s->sensor_events, s->accel[1], s->gyro[2]);
#endif

    // 2. The game rumbles the virtual gamepad: the helper forwards it to NS2 Bridge for the Bluetooth controller.
    fake_rumble(0x4000, 0x8000);
    ssize_t n = receive("NS2R", buf, sizeof buf);
    CHECK(n >= 23, "no rumble packet");
    if (n >= 23) {
        uint16_t lo, hi, product; uint32_t ms; uint64_t device;
        memcpy(&lo, buf + 4, 2); memcpy(&hi, buf + 6, 2); memcpy(&ms, buf + 8, 4);
        memcpy(&product, buf + 12, 2); memcpy(&device, buf + 14, 8);
        CHECK(lo == 0x4000 && hi == 0x8000 && ms == 0, "rumble %04X %04X %u ms", lo, hi, ms);
        CHECK(product == 0x2069 && device == UINT64_MAX, "rumble target %04X device %llx", product, (unsigned long long)device);
    }

    // 3. Updates stop (controller off, out of range, NS2 Bridge quit): the gamepad is detached after a second.
    usleep(1300000);
    SDL_PollEvent(NULL);
    CHECK(s->detached == 1 && s->closed == 1, "detached %d closed %d after updates stopped", s->detached, s->closed);

    printf("%s: helper virtual gamepad (%s)\n", failures ? "FAIL" : "PASS",
#ifdef FAKE_SDL3
           "SDL3"
#else
           "SDL2"
#endif
    );
    return failures ? 1 : 0;
}
