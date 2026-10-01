// ns2rumble.dylib — NS2 Bridge's game helper (SDL2 and SDL3).
//
// Loaded into a game either by NS2 Bridge at launch (DYLD_INSERT_LIBRARIES) or permanently, when the
// user chooses "Install into game" (NS2 Bridge adds a weak load command for it to the game's own SDL
// library). On load it:
//   1. applies per-game SDL settings from ~/Library/Application Support/NS2Bridge/games/<bundle id>.env.
//      They replace inherited values (NS2 Bridge's Finder-wide defaults are generic, the file is for this
//      game), except in a launch from NS2 Bridge (NS2_LAUNCHED=1), whose environment already has them;
//   2. redirects the game's calls to SDL's rumble / controller-type functions to the wrappers below by
//      rewriting the game's own symbol pointers (works under the hardened runtime, and for SDL loaded
//      later with dlopen);
//   3. forwards rumble for Nintendo controllers NS2 Bridge drives over UDP to 127.0.0.1:26761.
//
//   4. keeps SDL's N64 driver on: a game can't switch off the HIDAPI driver the NSO N64 controller needs
//      (without it SDL falls back to IOKit, which misreads the N64: phantom presses). Only that driver:
//      if a game switches all HIDAPI drivers off (e.g. to leave a Raphnet adapter to its own code), the
//      rest stay off, because each SDL driver checks its own hint before the master one;
//   5. reports which SDL driver each Nintendo controller got, so NS2 Bridge can warn if it's the wrong one
//      (checked from the game's own SDL_PollEvent / SDL_PeepEvents calls: 2 s after start, then every 5 s;
//      sent on change);
//   6. rescales stick axes for Nintendo controllers SDL reads through its generic IOKit backend: SDL maps
//      the raw 0–4095 range, but a GameCube stick only uses ~60% of it (Pro ~80%), so full tilt reached
//      only ~60% in games. NS2 Bridge passes each controller's calibration as
//      NS2_STICKCAL_<pid hex>=center,neg,pos ×4 axes (SDL gamepad units, after the mapping's inversions).
//
// Packets (little-endian):  "NS2H" u32 pid u8 sdlMajor          — hello, once
//                           "NS2R" u16 low u16 high u32 ms u16 pid u64 device u8 rank — rumble request;
//                                  device = IORegistry ID from SDL's path "DevSrvsID:<id>" (SDL's own
//                                  drivers), else 0; rank = position among the game's controllers of
//                                  this kind in connection order (0xFF unknown), so NS2 Bridge can tell
//                                  two identical controllers apart
//                           "NS2B" u32 pid u16 product u8 driver u8 sdlMajor — controller opened;
//                                  driver = SDL GUID byte 14 ('h' HIDAPI, 0 IOKit/other)
// Everything else passes straight through to SDL.

#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <unistd.h>

// Bumped whenever the helper changes, so NS2 Bridge can tell an installed copy is outdated.
__attribute__((used)) static const char ns2_version[] = "NS2RUMBLE_VERSION=7";

// ---------------------------------------------------------------- transport

static int sock = -1;
static struct sockaddr_in dest;
static int xbox_mode = 0;
static int hello_sent = 0;

static void ns2_send(const void *buf, size_t len) {
    if (sock >= 0) sendto(sock, buf, len, 0, (const struct sockaddr *)&dest, sizeof dest);
}

static void send_hello(uint8_t sdl_major) {
    if (hello_sent) return;
    hello_sent = 1;
    uint8_t p[9] = {'N', 'S', '2', 'H'};
    uint32_t pid = (uint32_t)getpid();
    memcpy(p + 4, &pid, 4);
    p[8] = sdl_major;
    ns2_send(p, sizeof p);
}

static void forward(uint16_t low, uint16_t high, uint32_t ms, uint16_t product, uint64_t device, uint8_t rank) {
    uint8_t p[23] = {'N', 'S', '2', 'R'};
    memcpy(p + 4, &low, 2);
    memcpy(p + 6, &high, 2);
    memcpy(p + 8, &ms, 4);
    memcpy(p + 12, &product, 2);
    memcpy(p + 14, &device, 8);
    p[22] = rank;
    ns2_send(p, sizeof p);
}

/// "DevSrvsID:<registry id>" (hidapi's path on macOS) → the id; anything else → 0.
static uint64_t device_from_path(const char *path) {
    if (!path || strncmp(path, "DevSrvsID:", 10) != 0) return 0;
    return strtoull(path + 10, NULL, 10);
}

// Switch 2 family (Xbox mode applies to these).
static int is_ns2(uint16_t v, uint16_t p) {
    return v == 0x057E && (p == 0x2066 || p == 0x2067 || p == 0x2069 || p == 0x2073);
}
// Everything NS2 Bridge drives rumble for: Switch 2 family + NSO N64.
static int is_supported(uint16_t v, uint16_t p) { return is_ns2(v, p) || (v == 0x057E && p == 0x2019); }

// ---------------------------------------------------------------- SDL functions (resolved at run time)
// No SDL symbols are linked: the helper works with SDL2, SDL3, or SDL loaded later.

typedef uint16_t (*u16_ptr_fn)(void *);
typedef uint16_t (*u16_int_fn)(int);
typedef uint16_t (*u16_u32_fn)(uint32_t);

static void *sym(void **cache, const char *name) {
    if (!*cache) *cache = dlsym(RTLD_DEFAULT, name);
    return *cache;
}
#define SYM(type, name) ((type)sym(&c_##name, #name))

static void *c_SDL_GameControllerGetVendor, *c_SDL_GameControllerGetProduct, *c_SDL_JoystickGetVendor,
    *c_SDL_JoystickGetProduct, *c_SDL_JoystickGetDeviceVendor, *c_SDL_JoystickGetDeviceProduct,
    *c_SDL_GetGamepadVendor, *c_SDL_GetGamepadProduct, *c_SDL_GetJoystickVendor, *c_SDL_GetJoystickProduct,
    *c_SDL_GetJoystickVendorForID, *c_SDL_GetJoystickProductForID;

/// Product ID if the object is a controller NS2 Bridge drives, else 0.
static uint16_t product_ptr(void *obj, u16_ptr_fn getv, u16_ptr_fn getp) {
    if (!obj || !getv || !getp) return 0;
    uint16_t v = getv(obj), p = getp(obj);
    return is_supported(v, p) ? p : 0;
}

// Which controller: the exact device when SDL knows its path, and its rank among same-kind controllers.
typedef const char *(*path_ptr_fn)(void *);
typedef void *(*ptr_ptr_fn2)(void *);
typedef int32_t (*i32_ptr_fn)(void *);
typedef int32_t (*i32_int_fn)(int);
typedef int (*count_fn)(void);
typedef uint32_t *(*list_fn)(int *);
typedef uint32_t (*u32_ptr_fn)(void *);
static void *c_SDL_GameControllerPath, *c_SDL_JoystickPath, *c_SDL_GameControllerGetJoystick2, *c_SDL_JoystickInstanceID,
    *c_SDL_NumJoysticks2, *c_SDL_JoystickGetDeviceInstanceID, *c_SDL_GetGamepadPath, *c_SDL_GetJoystickPath,
    *c_SDL_GetGamepadID, *c_SDL_GetJoystickID, *c_SDL_GetJoysticks2, *c_SDL_free2;

/// SDL2: rank of joystick instance `me` among connected joysticks with the same product (by instance ID).
static uint8_t rank2(int32_t me, uint16_t product) {
    count_fn n = (count_fn)sym(&c_SDL_NumJoysticks2, "SDL_NumJoysticks");
    i32_int_fn iid = (i32_int_fn)sym(&c_SDL_JoystickGetDeviceInstanceID, "SDL_JoystickGetDeviceInstanceID");
    u16_int_fn gp = SYM(u16_int_fn, SDL_JoystickGetDeviceProduct);
    if (!n || !iid || !gp || me < 0) return 0xFF;
    int r = 0, count = n();
    for (int i = 0; i < count; i++) if (gp(i) == product && iid(i) < me) r++;
    return (uint8_t)r;
}
/// SDL3: same, by joystick ID.
static uint8_t rank3(uint32_t me, uint16_t product) {
    list_fn list = (list_fn)sym(&c_SDL_GetJoysticks2, "SDL_GetJoysticks");
    u16_u32_fn gp = SYM(u16_u32_fn, SDL_GetJoystickProductForID);
    typedef void (*free_fn2)(void *);
    free_fn2 f = (free_fn2)sym(&c_SDL_free2, "SDL_free");
    if (!list || !gp || !me) return 0xFF;
    int n = 0, r = 0;
    uint32_t *ids = list(&n);
    if (!ids) return 0xFF;
    for (int i = 0; i < n; i++) if (gp(ids[i]) == product && ids[i] < me) r++;
    if (f) f(ids);
    return (uint8_t)r;
}

static const char *XBOX_NAME = "Xbox Wireless Controller";

// Originals, captured when the game's pointers are rewritten (fallback: dlsym).
static void *o_SDL_GameControllerRumble, *o_SDL_JoystickRumble, *o_SDL_GameControllerHasRumble,
    *o_SDL_GameControllerGetType, *o_SDL_GameControllerTypeForIndex, *o_SDL_GameControllerName,
    *o_SDL_GameControllerNameForIndex, *o_SDL_RumbleGamepad, *o_SDL_RumbleJoystick, *o_SDL_GetGamepadType,
    *o_SDL_GetGamepadTypeForID, *o_SDL_GetGamepadName, *o_SDL_GetGamepadNameForID,
    *o_SDL_SetHint, *o_SDL_SetHintWithPriority, *o_SDL_GameControllerOpen, *o_SDL_OpenGamepad, *o_SDL_PollEvent,
    *o_SDL_PeepEvents, *o_SDL_GameControllerGetAxis, *o_SDL_GetGamepadAxis;
#define ORIG(type, name) ((type)sym(&o_##name, #name))

// ---------------------------------------------------------------- SDL2 wrappers

typedef int (*rumble2_fn)(void *, uint16_t, uint16_t, uint32_t);
typedef int (*int_ptr_fn)(void *);
typedef int (*int_int_fn)(int);
typedef const char *(*str_ptr_fn)(void *);
typedef const char *(*str_int_fn)(int);

static int w_SDL_GameControllerRumble(void *gc, uint16_t lo, uint16_t hi, uint32_t ms) {
    send_hello(2);
    uint16_t p = product_ptr(gc, SYM(u16_ptr_fn, SDL_GameControllerGetVendor), SYM(u16_ptr_fn, SDL_GameControllerGetProduct));
    if (p) {
        path_ptr_fn path = (path_ptr_fn)sym(&c_SDL_GameControllerPath, "SDL_GameControllerPath");
        ptr_ptr_fn2 joy = (ptr_ptr_fn2)sym(&c_SDL_GameControllerGetJoystick2, "SDL_GameControllerGetJoystick");
        i32_ptr_fn iid = (i32_ptr_fn)sym(&c_SDL_JoystickInstanceID, "SDL_JoystickInstanceID");
        forward(lo, hi, ms, p, device_from_path(path ? path(gc) : NULL), joy && iid ? rank2(iid(joy(gc)), p) : 0xFF);
        return 0;
    }
    rumble2_fn f = ORIG(rumble2_fn, SDL_GameControllerRumble);
    return f ? f(gc, lo, hi, ms) : -1;
}

static int w_SDL_JoystickRumble(void *j, uint16_t lo, uint16_t hi, uint32_t ms) {
    send_hello(2);
    uint16_t p = product_ptr(j, SYM(u16_ptr_fn, SDL_JoystickGetVendor), SYM(u16_ptr_fn, SDL_JoystickGetProduct));
    if (p) {
        path_ptr_fn path = (path_ptr_fn)sym(&c_SDL_JoystickPath, "SDL_JoystickPath");
        i32_ptr_fn iid = (i32_ptr_fn)sym(&c_SDL_JoystickInstanceID, "SDL_JoystickInstanceID");
        forward(lo, hi, ms, p, device_from_path(path ? path(j) : NULL), iid ? rank2(iid(j), p) : 0xFF);
        return 0;
    }
    rumble2_fn f = ORIG(rumble2_fn, SDL_JoystickRumble);
    return f ? f(j, lo, hi, ms) : -1;
}

static int w_SDL_GameControllerHasRumble(void *gc) {
    if (product_ptr(gc, SYM(u16_ptr_fn, SDL_GameControllerGetVendor), SYM(u16_ptr_fn, SDL_GameControllerGetProduct))) return 1;
    int_ptr_fn f = ORIG(int_ptr_fn, SDL_GameControllerHasRumble);
    return f ? f(gc) : 0;
}

static int ns2_gc(void *gc) {
    u16_ptr_fn gv = SYM(u16_ptr_fn, SDL_GameControllerGetVendor), gp = SYM(u16_ptr_fn, SDL_GameControllerGetProduct);
    return xbox_mode && gc && gv && gp && is_ns2(gv(gc), gp(gc));
}
static int ns2_index(int i) {
    u16_int_fn gv = SYM(u16_int_fn, SDL_JoystickGetDeviceVendor), gp = SYM(u16_int_fn, SDL_JoystickGetDeviceProduct);
    return xbox_mode && gv && gp && is_ns2(gv(i), gp(i));
}

static int w_SDL_GameControllerGetType(void *gc) {
    if (ns2_gc(gc)) return 2;                                      // SDL_CONTROLLER_TYPE_XBOXONE
    int_ptr_fn f = ORIG(int_ptr_fn, SDL_GameControllerGetType);
    return f ? f(gc) : 0;
}
static int w_SDL_GameControllerTypeForIndex(int i) {
    if (ns2_index(i)) return 2;
    int_int_fn f = ORIG(int_int_fn, SDL_GameControllerTypeForIndex);
    return f ? f(i) : 0;
}
static const char *w_SDL_GameControllerName(void *gc) {
    if (ns2_gc(gc)) return XBOX_NAME;
    str_ptr_fn f = ORIG(str_ptr_fn, SDL_GameControllerName);
    return f ? f(gc) : NULL;
}
static const char *w_SDL_GameControllerNameForIndex(int i) {
    if (ns2_index(i)) return XBOX_NAME;
    str_int_fn f = ORIG(str_int_fn, SDL_GameControllerNameForIndex);
    return f ? f(i) : NULL;
}

// ---------------------------------------------------------------- SDL3 wrappers

typedef bool (*rumble3_fn)(void *, uint16_t, uint16_t, uint32_t);
typedef int (*int_u32_fn)(uint32_t);
typedef const char *(*str_u32_fn)(uint32_t);

static bool w_SDL_RumbleGamepad(void *g, uint16_t lo, uint16_t hi, uint32_t ms) {
    send_hello(3);
    uint16_t p = product_ptr(g, SYM(u16_ptr_fn, SDL_GetGamepadVendor), SYM(u16_ptr_fn, SDL_GetGamepadProduct));
    if (p) {
        path_ptr_fn path = (path_ptr_fn)sym(&c_SDL_GetGamepadPath, "SDL_GetGamepadPath");
        u32_ptr_fn gid = (u32_ptr_fn)sym(&c_SDL_GetGamepadID, "SDL_GetGamepadID");
        forward(lo, hi, ms, p, device_from_path(path ? path(g) : NULL), gid ? rank3(gid(g), p) : 0xFF);
        return true;
    }
    rumble3_fn f = ORIG(rumble3_fn, SDL_RumbleGamepad);
    return f ? f(g, lo, hi, ms) : false;
}

static bool w_SDL_RumbleJoystick(void *j, uint16_t lo, uint16_t hi, uint32_t ms) {
    send_hello(3);
    uint16_t p = product_ptr(j, SYM(u16_ptr_fn, SDL_GetJoystickVendor), SYM(u16_ptr_fn, SDL_GetJoystickProduct));
    if (p) {
        path_ptr_fn path = (path_ptr_fn)sym(&c_SDL_GetJoystickPath, "SDL_GetJoystickPath");
        u32_ptr_fn jid = (u32_ptr_fn)sym(&c_SDL_GetJoystickID, "SDL_GetJoystickID");
        forward(lo, hi, ms, p, device_from_path(path ? path(j) : NULL), jid ? rank3(jid(j), p) : 0xFF);
        return true;
    }
    rumble3_fn f = ORIG(rumble3_fn, SDL_RumbleJoystick);
    return f ? f(j, lo, hi, ms) : false;
}

static int ns2_gp(void *g) {
    u16_ptr_fn gv = SYM(u16_ptr_fn, SDL_GetGamepadVendor), gp = SYM(u16_ptr_fn, SDL_GetGamepadProduct);
    return xbox_mode && g && gv && gp && is_ns2(gv(g), gp(g));
}
static int ns2_id(uint32_t id) {
    u16_u32_fn gv = SYM(u16_u32_fn, SDL_GetJoystickVendorForID), gp = SYM(u16_u32_fn, SDL_GetJoystickProductForID);
    return xbox_mode && gv && gp && is_ns2(gv(id), gp(id));
}

static int w_SDL_GetGamepadType(void *g) {
    if (ns2_gp(g)) return 3;                                       // SDL_GAMEPAD_TYPE_XBOXONE
    int_ptr_fn f = ORIG(int_ptr_fn, SDL_GetGamepadType);
    return f ? f(g) : 0;
}
static int w_SDL_GetGamepadTypeForID(uint32_t id) {
    if (ns2_id(id)) return 3;
    int_u32_fn f = ORIG(int_u32_fn, SDL_GetGamepadTypeForID);
    return f ? f(id) : 0;
}
static const char *w_SDL_GetGamepadName(void *g) {
    if (ns2_gp(g)) return XBOX_NAME;
    str_ptr_fn f = ORIG(str_ptr_fn, SDL_GetGamepadName);
    return f ? f(g) : NULL;
}
static const char *w_SDL_GetGamepadNameForID(uint32_t id) {
    if (ns2_id(id)) return XBOX_NAME;
    str_u32_fn f = ORIG(str_u32_fn, SDL_GetGamepadNameForID);
    return f ? f(id) : NULL;
}

// ---------------------------------------------------------------- driver guard + report

/// Hints that would switch off SDL's N64 driver. (The master SDL_JOYSTICK_HIDAPI hint is left to the game:
/// SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC=1 in the environment keeps the N64 driver on regardless.)
static int disables_n64_driver(const char *name, const char *value) {
    if (!name || !value) return 0;
    if (strcmp(name, "SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC") != 0) return 0;
    return value[0] == '0' || strcasecmp(value, "false") == 0 || strcasecmp(value, "no") == 0 || strcasecmp(value, "off") == 0;
}

// SDL2 returns SDL_bool (int), SDL3 bool: only the low byte is used either way.
typedef int (*sethint_fn)(const char *, const char *);
typedef int (*sethintp_fn)(const char *, const char *, int);

static int w_SDL_SetHint(const char *name, const char *value) {
    if (disables_n64_driver(name, value)) return 1;               // pretend it worked; keep the driver on
    sethint_fn f = ORIG(sethint_fn, SDL_SetHint);
    return f ? (f(name, value) & 0xFF) != 0 : 0;
}
static int w_SDL_SetHintWithPriority(const char *name, const char *value, int priority) {
    if (disables_n64_driver(name, value)) return 1;
    sethintp_fn f = ORIG(sethintp_fn, SDL_SetHintWithPriority);
    return f ? (f(name, value, priority) & 0xFF) != 0 : 0;
}

typedef struct { uint8_t data[16]; } ns2_guid;
typedef ns2_guid (*guid_int_fn)(int);
typedef ns2_guid (*guid_u32_fn)(uint32_t);
static void *c_SDL_JoystickGetDeviceGUID, *c_SDL_GetJoystickGUIDForID;

static void report_driver(uint16_t vendor, uint16_t product, ns2_guid g, uint8_t sdl_major) {
    if (!is_supported(vendor, product)) return;
    // Send each (product, driver) pair once: the checks below run repeatedly.
    static uint32_t sent[16];
    static int nsent;
    uint32_t key = (uint32_t)product << 8 | g.data[14];
    for (int i = 0; i < nsent; i++) if (sent[i] == key) return;
    if (nsent < 16) sent[nsent++] = key;
    uint8_t p[12] = {'N', 'S', '2', 'B'};
    uint32_t pid = (uint32_t)getpid();
    memcpy(p + 4, &pid, 4);
    memcpy(p + 8, &product, 2);
    p[10] = g.data[14];
    p[11] = sdl_major;
    ns2_send(p, sizeof p);
}

// ---------------------------------------------------------------- stick rescaling

struct axis_cal { int center, neg, pos; };
struct stick_cal { uint16_t product; struct axis_cal ax[4]; };
static struct stick_cal stick_cals[4];
static int n_stick_cals;

static void load_stick_cals(void) {
    const uint16_t products[] = {0x2069, 0x2073, 0x2066, 0x2067};
    for (size_t i = 0; i < sizeof products / sizeof products[0] && n_stick_cals < 4; i++) {
        char key[32];
        snprintf(key, sizeof key, "NS2_STICKCAL_%04X", products[i]);
        const char *v = getenv(key);
        struct stick_cal c = {.product = products[i]};
        int *f = &c.ax[0].center;
        if (!v || sscanf(v, "%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d", f, f + 1, f + 2, f + 3, f + 4, f + 5,
                         f + 6, f + 7, f + 8, f + 9, f + 10, f + 11) != 12) continue;
        stick_cals[n_stick_cals++] = c;
    }
}

static int16_t rescale_axis(const struct axis_cal *a, int16_t v) {
    int d = v - a->center;
    long out = d >= 0 ? (a->pos > 0 ? (long)d * 32767 / a->pos : d) : (a->neg > 0 ? (long)d * 32768 / a->neg : d);
    return (int16_t)(out > 32767 ? 32767 : out < -32768 ? -32768 : out);
}

/// Calibration for this gamepad, if it's one SDL reads through IOKit (SDL's own drivers calibrate themselves).
typedef void *(*ptr_ptr_fn)(void *);
typedef ns2_guid (*guid_ptr_fn)(void *);
static void *c_SDL_GameControllerGetJoystick, *c_SDL_JoystickGetGUID, *c_SDL_GetGamepadJoystick, *c_SDL_GetJoystickGUID;

static const struct stick_cal *cal_for(void *pad, int sdl3) {
    if (!n_stick_cals || !pad) return NULL;
    static struct { void *pad; const struct stick_cal *cal; } cache[8];
    for (int i = 0; i < 8; i++) if (cache[i].pad == pad) return cache[i].cal;
    const struct stick_cal *found = NULL;
    u16_ptr_fn gv = sdl3 ? SYM(u16_ptr_fn, SDL_GetGamepadVendor) : SYM(u16_ptr_fn, SDL_GameControllerGetVendor);
    u16_ptr_fn gp = sdl3 ? SYM(u16_ptr_fn, SDL_GetGamepadProduct) : SYM(u16_ptr_fn, SDL_GameControllerGetProduct);
    ptr_ptr_fn joy = sdl3 ? SYM(ptr_ptr_fn, SDL_GetGamepadJoystick) : SYM(ptr_ptr_fn, SDL_GameControllerGetJoystick);
    guid_ptr_fn guid = sdl3 ? SYM(guid_ptr_fn, SDL_GetJoystickGUID) : SYM(guid_ptr_fn, SDL_JoystickGetGUID);
    if (gv && gp && joy && guid && gv(pad) == 0x057E && guid(joy(pad)).data[14] != 'h') {
        uint16_t p = gp(pad);
        for (int i = 0; i < n_stick_cals; i++) if (stick_cals[i].product == p) found = &stick_cals[i];
    }
    static int next;
    cache[next].pad = pad; cache[next].cal = found; next = (next + 1) % 8;
    return found;
}

typedef int16_t (*getaxis_fn)(void *, int);
static int16_t w_SDL_GameControllerGetAxis(void *gc, int axis) {
    getaxis_fn f = ORIG(getaxis_fn, SDL_GameControllerGetAxis);
    int16_t v = f ? f(gc, axis) : 0;
    const struct stick_cal *c = axis >= 0 && axis < 4 ? cal_for(gc, 0) : NULL;
    return c ? rescale_axis(&c->ax[axis], v) : v;
}
static int16_t w_SDL_GetGamepadAxis(void *g, int axis) {
    getaxis_fn f = ORIG(getaxis_fn, SDL_GetGamepadAxis);
    int16_t v = f ? f(g, axis) : 0;
    const struct stick_cal *c = axis >= 0 && axis < 4 ? cal_for(g, 1) : NULL;
    return c ? rescale_axis(&c->ax[axis], v) : v;
}

typedef void *(*open_int_fn)(int);
typedef void *(*open_u32_fn)(uint32_t);

// Look at every connected controller, whether or not the game uses it (a controller SDL misreads may not
// even count as a gamepad, so the game never opens it and the open wrappers below never see it).
typedef uint32_t *(*getjoysticks_fn)(int *);
typedef void (*free_fn)(void *);
static void *c_SDL_NumJoysticks, *c_SDL_GetJoysticks, *c_SDL_free;

static void scan_controllers(void) {
    int (*count2)(void) = (int (*)(void))sym(&c_SDL_NumJoysticks, "SDL_NumJoysticks");
    if (count2) {                                                   // SDL2 API (incl. sdl2-compat)
        u16_int_fn gv = SYM(u16_int_fn, SDL_JoystickGetDeviceVendor), gp = SYM(u16_int_fn, SDL_JoystickGetDeviceProduct);
        guid_int_fn gg = SYM(guid_int_fn, SDL_JoystickGetDeviceGUID);
        if (!gv || !gp || !gg) return;
        int n = count2();
        for (int i = 0; i < n && i < 16; i++) report_driver(gv(i), gp(i), gg(i), 2);
        return;
    }
    getjoysticks_fn list = (getjoysticks_fn)sym(&c_SDL_GetJoysticks, "SDL_GetJoysticks");
    u16_u32_fn gv = SYM(u16_u32_fn, SDL_GetJoystickVendorForID), gp = SYM(u16_u32_fn, SDL_GetJoystickProductForID);
    guid_u32_fn gg = SYM(guid_u32_fn, SDL_GetJoystickGUIDForID);
    free_fn f = (free_fn)sym(&c_SDL_free, "SDL_free");
    if (!list || !gv || !gp || !gg) return;
    int n = 0;
    uint32_t *ids = list(&n);
    if (!ids) return;
    for (int i = 0; i < n && i < 16; i++) report_driver(gv(ids[i]), gp(ids[i]), gg(ids[i]), 3);
    if (f) f(ids);
}

static void maybe_scan(void) {
    static uint64_t next;                                           // mach time; 0 = first call
    uint64_t now = mach_absolute_time();
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    uint64_t sec = (uint64_t)1000000000 * tb.denom / tb.numer;      // mach ticks per second
    if (!next) next = now + 2 * sec;                                // let SDL finish finding devices
    else if (now >= next) { next = now + 5 * sec; scan_controllers(); }
}

typedef int (*pollevent_fn)(void *);
static int w_SDL_PollEvent(void *event) {
    maybe_scan();
    pollevent_fn f = ORIG(pollevent_fn, SDL_PollEvent);
    return f ? f(event) : 0;
}

// SDL2 and SDL3 share this shape: (events, count, action, minType, maxType) → int.
typedef int (*peepevents_fn)(void *, int, int, uint32_t, uint32_t);
static int w_SDL_PeepEvents(void *events, int n, int action, uint32_t lo, uint32_t hi) {
    maybe_scan();
    peepevents_fn f = ORIG(peepevents_fn, SDL_PeepEvents);
    return f ? f(events, n, action, lo, hi) : -1;
}

static void *w_SDL_GameControllerOpen(int i) {
    open_int_fn f = ORIG(open_int_fn, SDL_GameControllerOpen);
    void *gc = f ? f(i) : NULL;
    u16_int_fn gv = SYM(u16_int_fn, SDL_JoystickGetDeviceVendor), gp = SYM(u16_int_fn, SDL_JoystickGetDeviceProduct);
    guid_int_fn gg = SYM(guid_int_fn, SDL_JoystickGetDeviceGUID);
    if (gc && gv && gp && gg) report_driver(gv(i), gp(i), gg(i), 2);
    return gc;
}
static void *w_SDL_OpenGamepad(uint32_t id) {
    open_u32_fn f = ORIG(open_u32_fn, SDL_OpenGamepad);
    void *g = f ? f(id) : NULL;
    u16_u32_fn gv = SYM(u16_u32_fn, SDL_GetJoystickVendorForID), gp = SYM(u16_u32_fn, SDL_GetJoystickProductForID);
    guid_u32_fn gg = SYM(guid_u32_fn, SDL_GetJoystickGUIDForID);
    if (g && gv && gp && gg) report_driver(gv(id), gp(id), gg(id), 3);
    return g;
}

// ---------------------------------------------------------------- symbol-pointer rewriting

struct rebind { const char *name; void *replacement; void **original; };

#define RB(name) { #name, (void *)w_##name, &o_##name }
static struct rebind rebinds[] = {
    RB(SDL_GameControllerRumble), RB(SDL_JoystickRumble), RB(SDL_GameControllerHasRumble),
    RB(SDL_GameControllerGetType), RB(SDL_GameControllerTypeForIndex),
    RB(SDL_GameControllerName), RB(SDL_GameControllerNameForIndex),
    RB(SDL_RumbleGamepad), RB(SDL_RumbleJoystick),
    RB(SDL_GetGamepadType), RB(SDL_GetGamepadTypeForID), RB(SDL_GetGamepadName), RB(SDL_GetGamepadNameForID),
    RB(SDL_SetHint), RB(SDL_SetHintWithPriority), RB(SDL_GameControllerOpen), RB(SDL_OpenGamepad), RB(SDL_PollEvent),
    RB(SDL_PeepEvents), RB(SDL_GameControllerGetAxis), RB(SDL_GetGamepadAxis),
};
static const size_t n_rebinds = sizeof rebinds / sizeof rebinds[0];

static void rebind_section(const struct section_64 *sect, intptr_t slide, const struct nlist_64 *symtab,
                           const char *strtab, const uint32_t *indirect) {
    const uint32_t *indices = indirect + sect->reserved1;
    void **slots = (void **)(slide + sect->addr);
    size_t count = sect->size / sizeof(void *);
    for (size_t i = 0; i < count; i++) {
        uint32_t idx = indices[i];
        if (idx & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) continue;
        const char *name = strtab + symtab[idx].n_un.n_strx;
        if (name[0] != '_' || strncmp(name + 1, "SDL_", 4) != 0) continue;
        for (size_t r = 0; r < n_rebinds; r++) {
            if (strcmp(name + 1, rebinds[r].name) != 0 || slots[i] == rebinds[r].replacement) continue;
            if (!*rebinds[r].original) *rebinds[r].original = slots[i];
            vm_address_t page = (vm_address_t)&slots[i] & ~(vm_address_t)(vm_page_size - 1);
            vm_protect(mach_task_self(), page, vm_page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
            slots[i] = rebinds[r].replacement;
            break;
        }
    }
}

static const struct mach_header *self_header;

static void rebind_image(const struct mach_header *mh, intptr_t slide) {
    if (mh == self_header || mh->magic != MH_MAGIC_64) return;
    Dl_info info;
    if (dladdr(mh, &info) && info.dli_fname && strstr(info.dli_fname, "libSDL")) return;   // leave SDL itself alone
    const struct mach_header_64 *h = (const struct mach_header_64 *)mh;
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *st = NULL;
    const struct dysymtab_command *dst = NULL;
    const uint8_t *cmd = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd;
        if (lc->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT) == 0)
            linkedit = (const struct segment_command_64 *)lc;
        else if (lc->cmd == LC_SYMTAB) st = (const struct symtab_command *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dst = (const struct dysymtab_command *)lc;
        cmd += lc->cmdsize;
    }
    if (!linkedit || !st || !dst || !dst->nindirectsyms) return;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symtab = (const struct nlist_64 *)(base + st->symoff);
    const char *strtab = (const char *)(base + st->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dst->indirectsymoff);

    cmd = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, "__DATA", 6) == 0 || strcmp(seg->segname, "__AUTH_CONST") == 0) {
                const struct section_64 *sect = (const struct section_64 *)(seg + 1);
                for (uint32_t s = 0; s < seg->nsects; s++) {
                    uint32_t type = sect[s].flags & SECTION_TYPE;
                    if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS)
                        rebind_section(&sect[s], slide, symtab, strtab, indirect);
                }
            }
        }
        cmd += lc->cmdsize;
    }
}

// ---------------------------------------------------------------- per-game settings

static void load_settings(void) {
    const char *launched = getenv("NS2_LAUNCHED");
    int overwrite = !(launched && launched[0] == '1');
    CFBundleRef b = CFBundleGetMainBundle();
    CFStringRef bundleID = b ? CFBundleGetIdentifier(b) : NULL;
    const char *home = getenv("HOME");
    char bid[256];
    if (!bundleID || !home || !CFStringGetCString(bundleID, bid, sizeof bid, kCFStringEncodingUTF8)) return;
    char path[1024];
    snprintf(path, sizeof path, "%s/Library/Application Support/NS2Bridge/games/%s.env", home, bid);
    FILE *f = fopen(path, "r");
    if (!f) return;
    // Lines: KEY=VALUE. A value may contain "\n" escapes (several SDL mapping lines).
    static char line[16384];
    while (fgets(line, sizeof line, f)) {
        size_t n = strlen(line);
        while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
        char *eq = strchr(line, '=');
        if (!eq || line[0] == '#') continue;
        *eq = 0;
        char *val = eq + 1, *w = val;
        for (char *r = val; *r; r++) {
            if (r[0] == '\\' && r[1] == 'n') { *w++ = '\n'; r++; } else *w++ = *r;
        }
        *w = 0;
        setenv(line, val, overwrite);
    }
    fclose(f);
}

// ---------------------------------------------------------------- start-up

__attribute__((constructor)) static void ns2_init(void) {
    Dl_info me;
    if (dladdr((void *)ns2_init, &me)) self_header = (const struct mach_header *)me.dli_fbase;

    load_settings();
    setenv("SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC", "1", 0);     // even without a settings file
    load_stick_cals();
    const char *x = getenv("NS2_XBOX_MODE");
    xbox_mode = x && x[0] == '1';

    sock = socket(AF_INET, SOCK_DGRAM, 0);
    memset(&dest, 0, sizeof dest);
    dest.sin_family = AF_INET;
    dest.sin_port = htons(26761);
    dest.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    // Called for every image already loaded and every one loaded later (dlopen).
    _dyld_register_func_for_add_image(rebind_image);

    // Say hello right away when SDL is already present (the rumble wrappers also say it).
    if (dlsym(RTLD_DEFAULT, "SDL_RumbleGamepad")) send_hello(3);
    else if (dlsym(RTLD_DEFAULT, "SDL_GameControllerRumble")) send_hello(2);
}
