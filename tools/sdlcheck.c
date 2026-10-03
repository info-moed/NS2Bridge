// sdlcheck: hands-off check that a game's own SDL reads Nintendo controllers through SDL's own drivers.
//
// Built and run by scripts/sdl-check.sh, linked against the game's SDL (SDL2, sdl2-compat or SDL3) the
// same way the game links it, so NS2 Bridge's helper can intercept its calls like it does in the game.
// It behaves like a hostile game: it tries to switch SDL's HIDAPI drivers off (at override priority).
// Then, for every Nintendo controller, it reports the driver SDL chose and counts input events while
// nobody touches anything. PASS = SDL's HIDAPI driver ('h') and no phantom input.
//
// Build: cc -DSDL_MAJOR=2|3 tools/sdlcheck.c <path to the game's libSDL> -rpath @executable_path/../Frameworks

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint8_t data[16]; } GUID;
typedef union { uint32_t type; uint8_t pad[128]; } Event;

#if SDL_MAJOR == 3
extern int16_t SDL_GetGamepadAxis(void *, int);
extern int SDL_Init(uint32_t);                    // bool in SDL3; only the low byte matters
extern int SDL_SetHint(const char *, const char *);
extern int SDL_SetHintWithPriority(const char *, const char *, int);
extern uint32_t *SDL_GetJoysticks(int *);
extern int SDL_IsGamepad(uint32_t);
extern void *SDL_OpenGamepad(uint32_t);
extern void *SDL_OpenJoystick(uint32_t);
extern GUID SDL_GetJoystickGUIDForID(uint32_t);
extern uint16_t SDL_GetJoystickVendorForID(uint32_t);
extern uint16_t SDL_GetJoystickProductForID(uint32_t);
extern const char *SDL_GetJoystickNameForID(uint32_t);
extern int SDL_PollEvent(Event *);
extern uint64_t SDL_GetTicks(void);
#define INIT_FLAGS (0x200u | 0x2000u | 0x4000u)   // joystick | gamepad | events
#else
extern int16_t SDL_GameControllerGetAxis(void *, int);
extern int SDL_Init(uint32_t);
extern int SDL_SetHint(const char *, const char *);
extern int SDL_SetHintWithPriority(const char *, const char *, int);
extern int SDL_NumJoysticks(void);
extern int SDL_IsGameController(int);
extern void *SDL_GameControllerOpen(int);
extern void *SDL_JoystickOpen(int);
extern GUID SDL_JoystickGetDeviceGUID(int);
extern uint16_t SDL_JoystickGetDeviceVendor(int);
extern uint16_t SDL_JoystickGetDeviceProduct(int);
extern const char *SDL_JoystickNameForIndex(int);
extern int SDL_PollEvent(Event *);
extern uint32_t SDL_GetTicks(void);
#define INIT_FLAGS (0x200u | 0x2000u | 0x4000u)   // joystick | gamecontroller | events
#endif

// Same values in SDL2 and SDL3.
enum { JOY_AXIS = 0x600, JOY_HAT = 0x602, JOY_BUTTON_DOWN = 0x603, PAD_AXIS = 0x650, PAD_BUTTON_DOWN = 0x651 };

static const char *driver_name(uint8_t d) { return d == 'h' ? "SDL HIDAPI driver" : d == 0 ? "IOKit (generic)" : "other"; }

int main(int argc, char **argv) {
    int secs = argc > 1 ? atoi(argv[1]) : 3;
    // SDLCHECK_HOSTILE: "override" (default) = what BattleShip does, plus switching the N64 driver off at the
    // strongest priority SDL has (SDL_HINT_OVERRIDE = 2, which beats environment variables);
    // "master" = all HIDAPI drivers off at override priority; "normal" = exactly what BattleShip does;
    // "none" = a well-behaved game.
    const char *hostile = getenv("SDLCHECK_HOSTILE") ? getenv("SDLCHECK_HOSTILE") : "override";
    if (strcmp(hostile, "master") == 0) SDL_SetHintWithPriority("SDL_JOYSTICK_HIDAPI", "0", 2);
    else if (strcmp(hostile, "none") != 0) SDL_SetHint("SDL_JOYSTICK_HIDAPI", "0");
    if (strcmp(hostile, "override") == 0) SDL_SetHintWithPriority("SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC", "0", 2);
    printf("Game behavior simulated: %s\n", hostile);
    if ((SDL_Init(INIT_FLAGS) & 0xFF) == 0 && SDL_MAJOR == 3) { printf("SDL_Init failed\n"); return 2; }

    Event e;
    uint64_t t0 = SDL_GetTicks();
    while (SDL_GetTicks() - t0 < 1500) SDL_PollEvent(&e);          // let devices arrive, drain start-up state

    int nintendo = 0, bad = 0;
    void *pads[16] = {0}; uint16_t pids[16] = {0}; int npads = 0;
#if SDL_MAJOR == 3
    int n = 0;
    uint32_t *ids = SDL_GetJoysticks(&n);
    for (int i = 0; i < n; i++) {
        uint32_t id = ids[i];
        uint16_t v = SDL_GetJoystickVendorForID(id), p = SDL_GetJoystickProductForID(id);
        GUID g = SDL_GetJoystickGUIDForID(id);
        const char *name = SDL_GetJoystickNameForID(id);
        int pad = SDL_IsGamepad(id) & 0xFF;
        void *opened = pad ? SDL_OpenGamepad(id) : (SDL_OpenJoystick(id), NULL);   // events only arrive for open devices
        if (opened && SDL_GetJoystickVendorForID(id) == 0x057E && npads < 16) { pads[npads] = opened; pids[npads++] = SDL_GetJoystickProductForID(id); }
#else
    int n = SDL_NumJoysticks();
    for (int i = 0; i < n; i++) {
        uint16_t v = SDL_JoystickGetDeviceVendor(i), p = SDL_JoystickGetDeviceProduct(i);
        GUID g = SDL_JoystickGetDeviceGUID(i);
        const char *name = SDL_JoystickNameForIndex(i);
        int pad = SDL_IsGameController(i);
        void *opened = pad ? SDL_GameControllerOpen(i) : (SDL_JoystickOpen(i), NULL);
        if (opened && SDL_JoystickGetDeviceVendor(i) == 0x057E && npads < 16) { pads[npads] = opened; pids[npads++] = SDL_JoystickGetDeviceProduct(i); }
#endif
        if (v != 0x057E) continue;
        nintendo++;
        // The NSO N64 (0x2019) is only read correctly by SDL's HIDAPI driver. (The Switch 2 family is fine on IOKit.)
        int needs_hidapi = p == 0x2019;
        int ok = !needs_hidapi || g.data[14] == 'h';
        if (!ok) bad++;
        printf("%s %04X:%04X %-28s driver: %-18s gamepad: %s\n", ok ? "  ok " : "  BAD", v, p, name ? name : "?",
               driver_name(g.data[14]), pad ? "yes" : "no");
    }
    if (!nintendo) { printf("No Nintendo controller connected: plug one in and run again.\n"); return 2; }

    if (getenv("SDLCHECK_AXES")) {
        // Stick range as the game sees it: move every stick around its edge while this runs.
        int lo[16][4], hi[16][4];
        for (int p = 0; p < npads; p++) for (int a = 0; a < 4; a++) { lo[p][a] = 0; hi[p][a] = 0; }
        printf("Roll every stick around its edge for %d s…\n", secs); fflush(stdout);
        t0 = SDL_GetTicks();
        while (SDL_GetTicks() - t0 < (uint64_t)secs * 1000) {
            while (SDL_PollEvent(&e)) {}
            for (int p = 0; p < npads; p++) for (int a = 0; a < 4; a++) {
#if SDL_MAJOR == 3
                int v = SDL_GetGamepadAxis(pads[p], a);
#else
                int v = SDL_GameControllerGetAxis(pads[p], a);
#endif
                if (v < lo[p][a]) lo[p][a] = v;
                if (v > hi[p][a]) hi[p][a] = v;
            }
        }
        const char *ax[4] = {"left X", "left Y", "right X", "right Y"};
        for (int p = 0; p < npads; p++) {
            printf("%04X:", pids[p]);
            for (int a = 0; a < 4; a++) printf("  %s %d..%d (%d%%/%d%%)", ax[a], lo[p][a], hi[p][a], lo[p][a] * -100 / 32768, hi[p][a] * 100 / 32767);
            printf("\n");
        }
        return 0;
    }
    printf("Hands off for %d s…\n", secs);
    fflush(stdout);
    int events = 0;
    t0 = SDL_GetTicks();
    while (SDL_GetTicks() - t0 < (uint64_t)secs * 1000) {
        while (SDL_PollEvent(&e)) {
            if (e.type == JOY_BUTTON_DOWN || e.type == PAD_BUTTON_DOWN || e.type == JOY_HAT) events++;
        }
    }
    printf("Button presses seen with nobody touching the controller: %d\n", events);
    int pass = bad == 0 && events == 0;
    printf("%s\n", pass ? "PASS: Nintendo controllers use SDL's own drivers; no phantom input."
                        : "FAIL: see above (a controller on IOKit reads garbage, or input arrived untouched).");
    return pass ? 0 : 1;
}
