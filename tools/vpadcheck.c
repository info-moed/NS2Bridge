// vpadcheck: hands-off check that a game's own SDL sees a Bluetooth controller through NS2 Bridge's helper.
//
// Built and run by scripts/vpad-check.sh, linked against the game's SDL the way the game links it, with the
// helper injected. Needs NS2 Bridge running with a Switch 2 controller connected over Bluetooth. For a few
// seconds it lists the gamepads SDL sees and, for NS2 Bridge's virtual gamepad (GUID byte 14 = 'v'), prints
// its sticks, triggers, buttons and, if the SDL supports it, gyro and accelerometer.
// PASS = a virtual gamepad appeared and its values changed or the gyro reported data.
//
// Build: cc -DSDL_MAJOR=2|3 tools/vpadcheck.c <path to the game's libSDL> -rpath @executable_path/../Frameworks

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint8_t data[16]; } GUID;
typedef union { uint32_t type; uint8_t pad[128]; } Event;

#if SDL_MAJOR == 3
extern int SDL_Init(uint32_t);
extern uint32_t *SDL_GetGamepads(int *);
extern void *SDL_OpenGamepad(uint32_t);
extern const char *SDL_GetGamepadNameForID(uint32_t);
extern GUID SDL_GetJoystickGUIDForID(uint32_t);
extern uint16_t SDL_GetJoystickProductForID(uint32_t);
extern int16_t SDL_GetGamepadAxis(void *, int);
extern int SDL_GetGamepadButton(void *, int);
extern int SDL_SetGamepadSensorEnabled(void *, int, int);
extern int SDL_GetGamepadSensorData(void *, int, float *, int);
extern int SDL_PollEvent(Event *);
extern uint64_t SDL_GetTicks(void);
#define INIT_FLAGS (0x200u | 0x2000u | 0x4000u)
#else
extern int SDL_Init(uint32_t);
extern int SDL_NumJoysticks(void);
extern int SDL_IsGameController(int);
extern void *SDL_GameControllerOpen(int);
extern const char *SDL_GameControllerNameForIndex(int);
extern GUID SDL_JoystickGetDeviceGUID(int);
extern uint16_t SDL_JoystickGetDeviceProduct(int);
extern int16_t SDL_GameControllerGetAxis(void *, int);
extern uint8_t SDL_GameControllerGetButton(void *, int);
extern int SDL_GameControllerSetSensorEnabled(void *, int, int) __attribute__((weak_import));
extern int SDL_GameControllerGetSensorData(void *, int, float *, int) __attribute__((weak_import));
extern int SDL_PollEvent(Event *);
extern uint32_t SDL_GetTicks(void);
#define INIT_FLAGS (0x200u | 0x2000u | 0x4000u)
#endif

int main(int argc, char **argv) {
    int seconds = argc > 1 ? (int)strtol(argv[1], NULL, 10) : 6;
    if ((SDL_Init(INIT_FLAGS) & 0xFF) != (SDL_MAJOR == 3 ? 1 : 0)) { printf("SDL_Init failed\n"); return 2; }
    void *pad = NULL;
    int sensors = 0, changes = 0, gyro_reports = 0;
    int16_t last[6] = {0};
    uint32_t last_buttons = 0;
    uint64_t start = SDL_GetTicks(), next_print = start + 1000;
    Event e;
    while (SDL_GetTicks() - start < (uint64_t)seconds * 1000) {
        while (SDL_PollEvent(&e)) {}
        if (!pad) {
#if SDL_MAJOR == 3
            int n = 0;
            uint32_t *ids = SDL_GetGamepads(&n);
            for (int i = 0; ids && i < n && !pad; i++) {
                GUID g = SDL_GetJoystickGUIDForID(ids[i]);
                if (g.data[14] != 'v') continue;
                printf("virtual gamepad: \"%s\" product %04X\n", SDL_GetGamepadNameForID(ids[i]), SDL_GetJoystickProductForID(ids[i]));
                pad = SDL_OpenGamepad(ids[i]);
                sensors = pad && (SDL_SetGamepadSensorEnabled(pad, 2, 1) & 0xFF) && (SDL_SetGamepadSensorEnabled(pad, 1, 1) & 0xFF);
            }
#else
            for (int i = 0; i < SDL_NumJoysticks() && !pad; i++) {
                GUID g = SDL_JoystickGetDeviceGUID(i);
                if (g.data[14] != 'v' || !SDL_IsGameController(i)) continue;
                printf("virtual gamepad: \"%s\" product %04X\n", SDL_GameControllerNameForIndex(i), SDL_JoystickGetDeviceProduct(i));
                pad = SDL_GameControllerOpen(i);
                sensors = pad && SDL_GameControllerSetSensorEnabled && SDL_GameControllerSetSensorEnabled(pad, 2, 1) == 0
                          && SDL_GameControllerSetSensorEnabled(pad, 1, 1) == 0;
            }
#endif
            if (pad) printf("motion sensors: %s\n", sensors ? "on" : "not available");
            continue;
        }
        int16_t ax[6];
        uint32_t buttons = 0;
        for (int i = 0; i < 6; i++) {
#if SDL_MAJOR == 3
            ax[i] = SDL_GetGamepadAxis(pad, i);
#else
            ax[i] = SDL_GameControllerGetAxis(pad, i);
#endif
        }
        for (int b = 0; b < 16; b++) {
#if SDL_MAJOR == 3
            if (SDL_GetGamepadButton(pad, b) & 0xFF) buttons |= 1u << b;
#else
            if (SDL_GameControllerGetButton(pad, b)) buttons |= 1u << b;
#endif
        }
        if (memcmp(ax, last, sizeof ax) != 0 || buttons != last_buttons) changes++;
        memcpy(last, ax, sizeof ax);
        last_buttons = buttons;
        float gyro[3] = {0}, accel[3] = {0};
        if (sensors) {
#if SDL_MAJOR == 3
            int ok = (SDL_GetGamepadSensorData(pad, 2, gyro, 3) & 0xFF) && (SDL_GetGamepadSensorData(pad, 1, accel, 3) & 0xFF);
#else
            int ok = SDL_GameControllerGetSensorData(pad, 2, gyro, 3) == 0 && SDL_GameControllerGetSensorData(pad, 1, accel, 3) == 0;
#endif
            if (ok && (accel[0] != 0 || accel[1] != 0 || accel[2] != 0)) gyro_reports++;
        }
        if (SDL_GetTicks() >= next_print) {
            next_print += 1000;
            printf("sticks %6d %6d %6d %6d  triggers %6d %6d  buttons %04X", ax[0], ax[1], ax[2], ax[3], ax[4], ax[5], buttons);
            if (sensors) printf("  accel %+6.2f %+6.2f %+6.2f m/s²  gyro %+6.2f %+6.2f %+6.2f rad/s",
                                accel[0], accel[1], accel[2], gyro[0], gyro[1], gyro[2]);
            printf("\n");
        }
    }
    if (!pad) { printf("FAIL: no virtual gamepad (is NS2 Bridge running with a Bluetooth controller?)\n"); return 1; }
    printf("%s: virtual gamepad present; %d state changes, %d motion readings\n",
           changes > 1 || gyro_reports > 0 ? "PASS" : "PASS (no movement seen)", changes, gyro_reports);
    return 0;
}
