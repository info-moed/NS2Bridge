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
//   7. presents Bluetooth controllers to the game: games can't see Switch 2 controllers over Bluetooth (NS2
//      Bridge holds the connection), so NS2 Bridge streams them here and the helper attaches an SDL virtual
//      gamepad per controller (SDL 2.24+ or SDL3; gyro and accelerometer with SDL3, which has virtual sensors).
//      Attached and detached from the game's own event calls; rumble goes back to that Bluetooth controller.
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
//                                  driver = SDL GUID byte 14 ('h' HIDAPI, 'v' virtual, 0 IOKit/other)
//                           "NS2K" u32 pid — keep-alive, every second: NS2 Bridge then streams
//                                  "NS2V" packets (Bluetooth controllers, see VirtualGamepad.swift) back
//                           device UINT64_MAX in "NS2R" = the Bluetooth controller behind a virtual gamepad
// Everything else passes straight through to SDL.

#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <unistd.h>

// Bumped whenever the helper changes, so NS2 Bridge can tell an installed copy is outdated.
__attribute__((used)) static const char ns2_version[] = "NS2RUMBLE_VERSION=8";

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

typedef struct { uint8_t data[16]; } ns2_guid;

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

// Virtual gamepads (Bluetooth controllers), defined below.
#define BLUETOOTH_DEVICE UINT64_MAX
typedef ns2_guid (*guid_ptr_fn)(void *);
static int is_virtual_guid(ns2_guid g);
static void vpad_service(void);
static void *c_SDL_JoystickGetGUIDv, *c_SDL_GetGamepadJoystickv, *c_SDL_GetJoystickGUIDv;

// Originals, captured when the game's pointers are rewritten (fallback: dlsym).
static void *o_SDL_GameControllerRumble, *o_SDL_JoystickRumble, *o_SDL_GameControllerHasRumble,
    *o_SDL_GameControllerGetType, *o_SDL_GameControllerTypeForIndex, *o_SDL_GameControllerName,
    *o_SDL_GameControllerNameForIndex, *o_SDL_RumbleGamepad, *o_SDL_RumbleJoystick, *o_SDL_GetGamepadType,
    *o_SDL_GetGamepadTypeForID, *o_SDL_GetGamepadName, *o_SDL_GetGamepadNameForID,
    *o_SDL_SetHint, *o_SDL_SetHintWithPriority, *o_SDL_GameControllerOpen, *o_SDL_OpenGamepad, *o_SDL_PollEvent,
    *o_SDL_PeepEvents, *o_SDL_GameControllerGetAxis, *o_SDL_GetGamepadAxis, *o_SDL_PumpEvents;
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
        guid_ptr_fn guid = (guid_ptr_fn)sym(&c_SDL_JoystickGetGUIDv, "SDL_JoystickGetGUID");
        if (joy && guid && is_virtual_guid(guid(joy(gc)))) forward(lo, hi, ms, p, BLUETOOTH_DEVICE, 0xFF);
        else forward(lo, hi, ms, p, device_from_path(path ? path(gc) : NULL), joy && iid ? rank2(iid(joy(gc)), p) : 0xFF);
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
        guid_ptr_fn guid = (guid_ptr_fn)sym(&c_SDL_JoystickGetGUIDv, "SDL_JoystickGetGUID");
        if (guid && is_virtual_guid(guid(j))) forward(lo, hi, ms, p, BLUETOOTH_DEVICE, 0xFF);
        else forward(lo, hi, ms, p, device_from_path(path ? path(j) : NULL), iid ? rank2(iid(j), p) : 0xFF);
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
        ptr_ptr_fn2 joy = (ptr_ptr_fn2)sym(&c_SDL_GetGamepadJoystickv, "SDL_GetGamepadJoystick");
        guid_ptr_fn guid = (guid_ptr_fn)sym(&c_SDL_GetJoystickGUIDv, "SDL_GetJoystickGUID");
        if (joy && guid && is_virtual_guid(guid(joy(g)))) forward(lo, hi, ms, p, BLUETOOTH_DEVICE, 0xFF);
        else forward(lo, hi, ms, p, device_from_path(path ? path(g) : NULL), gid ? rank3(gid(g), p) : 0xFF);
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
        guid_ptr_fn guid = (guid_ptr_fn)sym(&c_SDL_GetJoystickGUIDv, "SDL_GetJoystickGUID");
        if (guid && is_virtual_guid(guid(j))) forward(lo, hi, ms, p, BLUETOOTH_DEVICE, 0xFF);
        else forward(lo, hi, ms, p, device_from_path(path ? path(j) : NULL), jid ? rank3(jid(j), p) : 0xFF);
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

// ---------------------------------------------------------------- Bluetooth controllers as virtual gamepads

#define VPADS 8
struct vpad_state {
    uint8_t slot, flags;                  // flags bit 0: motion valid
    uint16_t product;
    uint32_t buttons;                     // bit n = SDL gamepad button n
    int16_t axes[6];                      // SDL gamepad axes; triggers -32768 at rest
    float accel[3], gyro[3];              // m/s², rad/s, SDL frame
    uint64_t sensor_us;
};
static struct vpad {
    int used;                             // has state (guarded by vlock)
    struct vpad_state s;
    uint64_t seen;                        // mach time of the last update
    // Game thread only:
    int attached;
    uint32_t id;                          // SDL3 joystick ID / SDL2 instance ID
    void *joy;                            // our own open handle (for the virtual setters)
    uint64_t sent_sensor_us;
} vpads[VPADS];
static pthread_mutex_t vlock = PTHREAD_MUTEX_INITIALIZER;
static mach_timebase_info_data_t vtb;

static uint64_t ticks_per_second(void) {
    if (!vtb.denom) mach_timebase_info(&vtb);
    return (uint64_t)1000000000 * vtb.denom / vtb.numer;
}

static float f32_at(const uint8_t *p) { float f; memcpy(&f, p, 4); return f; }

/// NS2 Bridge's "NS2V" stream (VirtualGamepad.swift): latest state per slot.
static void *vpad_receive(void *arg) {
    (void)arg;
    uint8_t buf[6 + VPADS * 52];
    for (;;) {
        ssize_t n = recv(sock, buf, sizeof buf, 0);
        if (n < 6 || memcmp(buf, "NS2V", 4) != 0 || buf[4] != 1) continue;
        int count = buf[5];
        if (count > VPADS || 6 + count * 52 > n) continue;
        uint64_t now = mach_absolute_time();
        pthread_mutex_lock(&vlock);
        for (int e = 0; e < count; e++) {
            const uint8_t *p = buf + 6 + e * 52;
            struct vpad_state st = {.slot = p[0], .flags = p[1]};
            memcpy(&st.product, p + 2, 2);
            memcpy(&st.buttons, p + 4, 4);
            memcpy(st.axes, p + 8, 12);
            for (int i = 0; i < 3; i++) { st.accel[i] = f32_at(p + 20 + 4 * i); st.gyro[i] = f32_at(p + 32 + 4 * i); }
            memcpy(&st.sensor_us, p + 44, 8);
            int k = -1;
            for (int i = 0; i < VPADS; i++) if (vpads[i].used && vpads[i].s.slot == st.slot) { k = i; break; }
            for (int i = 0; k < 0 && i < VPADS; i++) if (!vpads[i].used && !vpads[i].attached) k = i;
            if (k < 0) continue;
            vpads[k].used = 1;
            vpads[k].s = st;
            vpads[k].seen = now;
        }
        pthread_mutex_unlock(&vlock);
    }
    return NULL;
}

/// Tells NS2 Bridge this game wants Bluetooth controllers (it streams while keep-alives arrive).
static void *vpad_keepalive(void *arg) {
    (void)arg;
    uint8_t p[8] = {'N', 'S', '2', 'K'};
    uint32_t pid = (uint32_t)getpid();
    memcpy(p + 4, &pid, 4);
    for (;;) { ns2_send(p, sizeof p); sleep(1); }
    return NULL;
}

// SDL3 (also under sdl2-compat, which runs SDL3): SDL_VirtualJoystickDesc as of SDL 3.2.
typedef struct { int32_t type; float rate; } v3_sensor;
typedef struct {
    uint32_t version;
    uint16_t type, padding, vendor_id, product_id, naxes, nbuttons, nballs, nhats, ntouchpads, nsensors, padding2[2];
    uint32_t button_mask, axis_mask;
    const char *name;
    const void *touchpads;
    const v3_sensor *sensors;
    void *userdata;
    void (*Update)(void *);
    void (*SetPlayerIndex)(void *, int);
    bool (*Rumble)(void *, uint16_t, uint16_t);
    bool (*RumbleTriggers)(void *, uint16_t, uint16_t);
    bool (*SetLED)(void *, uint8_t, uint8_t, uint8_t);
    bool (*SendEffect)(void *, const void *, int);
    bool (*SetSensorsEnabled)(void *, bool);
    void (*Cleanup)(void *);
} v3_desc;
// SDL2 (2.24+): SDL_VirtualJoystickDesc, version 1.
typedef struct {
    uint16_t version, type, naxes, nbuttons, nhats, vendor_id, product_id, padding;
    uint32_t button_mask, axis_mask;
    const char *name;
    void *userdata;
    void (*Update)(void *);
    void (*SetPlayerIndex)(void *, int);
    int (*Rumble)(void *, uint16_t, uint16_t);
    int (*RumbleTriggers)(void *, uint16_t, uint16_t);
    int (*SetLED)(void *, uint8_t, uint8_t, uint8_t);
    int (*SendEffect)(void *, const void *, int);
} v2_desc;

static void *c_SDL_WasInit, *c_SDL_AttachVirtualJoystick, *c_SDL_DetachVirtualJoystick, *c_SDL_OpenJoystick,
    *c_SDL_CloseJoystick, *c_SDL_SetJoystickVirtualAxis, *c_SDL_SetJoystickVirtualButton,
    *c_SDL_SendJoystickVirtualSensorData, *c_SDL_JoystickAttachVirtualEx, *c_SDL_JoystickDetachVirtual,
    *c_SDL_JoystickOpen, *c_SDL_JoystickClose, *c_SDL_JoystickSetVirtualAxis, *c_SDL_JoystickSetVirtualButton,
    *c_SDL_JoystickInstanceID2, *c_SDL_NumJoysticks3, *c_SDL_JoystickGetDeviceInstanceID2;

/// SDL3, also when sdl2-compat loaded it privately (RTLD_LOCAL: not visible to a global dlsym), so games
/// built on sdl2-compat still get SDL3's virtual sensors. Looked up among the loaded images until found.
static void *sdl3_lib(void) {
    static void *handle;
    if (handle) return handle;
    for (uint32_t i = 0; i < _dyld_image_count() && !handle; i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && (strstr(n, "/libSDL3") || strstr(n, "/SDL3.framework/"))) handle = dlopen(n, RTLD_LAZY | RTLD_NOLOAD);
    }
    return handle;
}
static void *sym3(void **cache, const char *name) {
    if (!*cache) { void *h = sdl3_lib(); *cache = h ? dlsym(h, name) : NULL; }
    return *cache;
}
#define S3(type, name) ((type)sym3(&c_##name, #name))

/// 3 = SDL3 virtual joysticks (with sensors), 2 = SDL2's (2.24+), 0 = none (yet): decided once SDL is up.
static int vpad_flavor;
static int vpad_sdl3(void) { return vpad_flavor == 3; }

static void vpad_update(void *userdata) {
    struct vpad *v = &vpads[(intptr_t)userdata];
    if (!v->joy) return;
    pthread_mutex_lock(&vlock);
    struct vpad_state st = v->s;
    pthread_mutex_unlock(&vlock);
    if (vpad_sdl3()) {
        bool (*axis)(void *, int, int16_t) = (bool (*)(void *, int, int16_t))S3(void *, SDL_SetJoystickVirtualAxis);
        bool (*button)(void *, int, bool) = (bool (*)(void *, int, bool))S3(void *, SDL_SetJoystickVirtualButton);
        bool (*sensor)(void *, int32_t, uint64_t, const float *, int) =
            (bool (*)(void *, int32_t, uint64_t, const float *, int))S3(void *, SDL_SendJoystickVirtualSensorData);
        if (!axis || !button) return;
        for (int i = 0; i < 6; i++) axis(v->joy, i, st.axes[i]);
        for (int i = 0; i < 16; i++) button(v->joy, i, (st.buttons >> i) & 1);
        if (sensor && (st.flags & 1) && st.sensor_us != v->sent_sensor_us) {
            v->sent_sensor_us = st.sensor_us;
            sensor(v->joy, 1, st.sensor_us * 1000, st.accel, 3);          // SDL_SENSOR_ACCEL
            sensor(v->joy, 2, st.sensor_us * 1000, st.gyro, 3);           // SDL_SENSOR_GYRO
        }
    } else {
        int (*axis)(void *, int, int16_t) = (int (*)(void *, int, int16_t))SYM(void *, SDL_JoystickSetVirtualAxis);
        int (*button)(void *, int, uint8_t) = (int (*)(void *, int, uint8_t))SYM(void *, SDL_JoystickSetVirtualButton);
        if (!axis || !button) return;
        for (int i = 0; i < 6; i++) axis(v->joy, i, st.axes[i]);
        for (int i = 0; i < 16; i++) button(v->joy, i, (st.buttons >> i) & 1);
    }
}

static void vpad_rumble(void *userdata, uint16_t lo, uint16_t hi) {
    struct vpad *v = &vpads[(intptr_t)userdata];
    forward(lo, hi, 0, v->s.product, BLUETOOTH_DEVICE, 0xFF);    // 0 ms: until the next request (SDL stops it)
}
static bool vpad_rumble3(void *u, uint16_t lo, uint16_t hi) { vpad_rumble(u, lo, hi); return true; }
static int vpad_rumble2(void *u, uint16_t lo, uint16_t hi) { vpad_rumble(u, lo, hi); return 0; }
static bool vpad_sensors3(void *u, bool on) { (void)u; (void)on; return true; }

static const char *vpad_name(uint16_t product) {
    return product == 0x2073 ? "Nintendo GameCube Controller" : "Nintendo Switch 2 Pro Controller";
}

static void vpad_attach(int k) {
    struct vpad *v = &vpads[k];
    uint16_t product = v->s.product;
    if (vpad_sdl3()) {
        static const v3_sensor sensors[2] = {{1, 0}, {2, 0}};          // accelerometer, gyro
        v3_desc d = {0};
        d.version = sizeof d;
        d.type = 1;                                                   // SDL_JOYSTICK_TYPE_GAMEPAD
        d.vendor_id = 0x057E; d.product_id = product;
        d.naxes = 6; d.nbuttons = 16;
        d.nsensors = product == 0x2069 ? 2 : 0;                       // the Pro has an IMU
        d.sensors = d.nsensors ? sensors : NULL;
        d.button_mask = 0xFFFF; d.axis_mask = 0x3F;
        d.name = vpad_name(product);
        d.userdata = (void *)(intptr_t)k;
        d.Update = vpad_update; d.Rumble = vpad_rumble3; d.SetSensorsEnabled = vpad_sensors3;
        uint32_t (*attach)(const v3_desc *) = (uint32_t (*)(const v3_desc *))S3(void *, SDL_AttachVirtualJoystick);
        void *(*open)(uint32_t) = (void *(*)(uint32_t))S3(void *, SDL_OpenJoystick);
        uint32_t id = attach(&d);
        if (!id) return;
        v->id = id;
        v->joy = open(id);
    } else {
        int (*attach)(const v2_desc *) = (int (*)(const v2_desc *))SYM(void *, SDL_JoystickAttachVirtualEx);
        void *(*open)(int) = (void *(*)(int))SYM(void *, SDL_JoystickOpen);
        int32_t (*iid)(void *) = (int32_t (*)(void *))sym(&c_SDL_JoystickInstanceID2, "SDL_JoystickInstanceID");
        if (!attach || !open || !iid) return;
        v2_desc d = {0};
        d.version = 1;
        d.type = 1;                                                   // SDL_JOYSTICK_TYPE_GAMECONTROLLER
        d.naxes = 6; d.nbuttons = 16;
        d.vendor_id = 0x057E; d.product_id = product;
        d.button_mask = 0xFFFF; d.axis_mask = 0x3F;
        d.name = vpad_name(product);
        d.userdata = (void *)(intptr_t)k;
        d.Update = vpad_update; d.Rumble = vpad_rumble2;
        int index = attach(&d);
        if (index < 0) return;
        v->joy = open(index);
        if (!v->joy) return;
        v->id = (uint32_t)iid(v->joy);
    }
    v->attached = 1;
    v->sent_sensor_us = 0;
}

static void vpad_detach(int k) {
    struct vpad *v = &vpads[k];
    if (vpad_sdl3()) {
        void (*close)(void *) = (void (*)(void *))S3(void *, SDL_CloseJoystick);
        bool (*detach)(uint32_t) = (bool (*)(uint32_t))S3(void *, SDL_DetachVirtualJoystick);
        if (v->joy && close) close(v->joy);
        if (detach) detach(v->id);
    } else {
        void (*close)(void *) = (void (*)(void *))SYM(void *, SDL_JoystickClose);
        int (*detach)(int) = (int (*)(int))SYM(void *, SDL_JoystickDetachVirtual);
        int (*count)(void) = (int (*)(void))sym(&c_SDL_NumJoysticks3, "SDL_NumJoysticks");
        int32_t (*iid)(int) = (int32_t (*)(int))sym(&c_SDL_JoystickGetDeviceInstanceID2, "SDL_JoystickGetDeviceInstanceID");
        if (v->joy && close) close(v->joy);
        if (detach && count && iid) {                                 // device indices shift: find ours
            int n = count();
            for (int i = 0; i < n; i++) if ((uint32_t)iid(i) == v->id) { detach(i); break; }
        }
    }
    v->attached = 0;
    v->joy = NULL;
}

/// From the game's own event calls: attach a gamepad for each streaming Bluetooth controller, detach those
/// that stopped (no update for 1 s: turned off, out of range, or NS2 Bridge quit).
static void *c_SDL_WasInit3;
static void vpad_service(void) {
    if (!vpad_flavor) {
        if (S3(void *, SDL_AttachVirtualJoystick) && S3(void *, SDL_OpenJoystick)) vpad_flavor = 3;
        else if (SYM(void *, SDL_JoystickAttachVirtualEx)) vpad_flavor = 2;
        else return;                                                  // no SDL (yet), or one too old
    }
    uint32_t (*was_init)(uint32_t) = vpad_flavor == 3 ? (uint32_t (*)(uint32_t))sym3(&c_SDL_WasInit3, "SDL_WasInit")
                                                      : (uint32_t (*)(uint32_t))SYM(void *, SDL_WasInit);
    if (!was_init) return;
    if (!(was_init(0x200) & 0x200)) {                                 // SDL_INIT_JOYSTICK not (or no longer) up
        for (int k = 0; k < VPADS; k++) { vpads[k].attached = 0; vpads[k].joy = NULL; }
        return;
    }
    uint64_t now = mach_absolute_time(), stale = ticks_per_second();
    for (int k = 0; k < VPADS; k++) {
        pthread_mutex_lock(&vlock);
        int fresh = vpads[k].used && now - vpads[k].seen < stale;
        if (vpads[k].used && !fresh) vpads[k].used = 0;
        pthread_mutex_unlock(&vlock);
        if (fresh && !vpads[k].attached) vpad_attach(k);
        else if (!fresh && vpads[k].attached) vpad_detach(k);
    }
}

/// Is this SDL joystick one of our virtual gamepads? (SDL GUID byte 14 is 'v' for virtual joysticks.)
static int is_virtual_guid(ns2_guid g) { return g.data[14] == 'v'; }

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
    ns2_guid g = gv && gp && joy && guid ? guid(joy(pad)) : (ns2_guid){{0}};
    if (gv && gp && joy && guid && gv(pad) == 0x057E && g.data[14] != 'h' && !is_virtual_guid(g)) {
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
    vpad_service();
    pollevent_fn f = ORIG(pollevent_fn, SDL_PollEvent);
    return f ? f(event) : 0;
}

// SDL2 and SDL3 share this shape: (events, count, action, minType, maxType) → int.
typedef int (*peepevents_fn)(void *, int, int, uint32_t, uint32_t);
static int w_SDL_PeepEvents(void *events, int n, int action, uint32_t lo, uint32_t hi) {
    maybe_scan();
    vpad_service();
    peepevents_fn f = ORIG(peepevents_fn, SDL_PeepEvents);
    return f ? f(events, n, action, lo, hi) : -1;
}

typedef void (*pump_fn)(void);
static void w_SDL_PumpEvents(void) {
    vpad_service();
    pump_fn f = ORIG(pump_fn, SDL_PumpEvents);
    if (f) f();
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
    RB(SDL_PeepEvents), RB(SDL_GameControllerGetAxis), RB(SDL_GetGamepadAxis), RB(SDL_PumpEvents),
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
    struct sockaddr_in local = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    if (sock >= 0 && bind(sock, (const struct sockaddr *)&local, sizeof local) == 0) {   // port for NS2 Bridge's stream
        pthread_t t;
        if (pthread_create(&t, NULL, vpad_receive, NULL) == 0) pthread_detach(t);
        if (pthread_create(&t, NULL, vpad_keepalive, NULL) == 0) pthread_detach(t);
    }

    // Called for every image already loaded and every one loaded later (dlopen).
    _dyld_register_func_for_add_image(rebind_image);

    // Say hello right away when SDL is already present (the rumble wrappers also say it).
    if (dlsym(RTLD_DEFAULT, "SDL_RumbleGamepad")) send_hello(3);
    else if (dlsym(RTLD_DEFAULT, "SDL_GameControllerRumble")) send_hello(2);
}
