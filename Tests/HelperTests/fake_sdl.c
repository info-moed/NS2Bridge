// A fake SDL for the helper's end-to-end test: just enough of SDL's virtual-joystick API to record what the
// helper does. Built twice: -DFAKE_SDL3 as libSDL3.0.dylib, otherwise as libSDL2-2.0.0.dylib (the names matter:
// the helper finds SDL3 among the loaded images by name).
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

typedef struct { int32_t type; float rate; } sensor_desc;
typedef struct {
    int attached, detached, opened, closed;
    uint16_t product, nsensors, nbuttons, naxes;
    int16_t axes[8];
    uint32_t buttons;
    float accel[3], gyro[3];
    int sensor_events;
    void *userdata;
    void (*update)(void *);
    void *rumble;                       // bool(*)(void*,u16,u16) on SDL3, int(*)(…) on SDL2
} fake_state_t;

static fake_state_t state;
fake_state_t *fake_state(void) { return &state; }
static int joystick;                    // the one virtual joystick's handle (address used as SDL_Joystick*)

uint32_t SDL_WasInit(uint32_t flags) { return flags & 0x200; }

int SDL_PollEvent(void *event) {        // SDL updates joysticks while pumping events
    (void)event;
    if (state.attached > state.detached && state.update) state.update(state.userdata);
    return 0;
}

#ifdef FAKE_SDL3
typedef struct {
    uint32_t version;
    uint16_t type, padding, vendor_id, product_id, naxes, nbuttons, nballs, nhats, ntouchpads, nsensors, padding2[2];
    uint32_t button_mask, axis_mask;
    const char *name;
    const void *touchpads;
    const sensor_desc *sensors;
    void *userdata;
    void (*Update)(void *);
    void (*SetPlayerIndex)(void *, int);
    bool (*Rumble)(void *, uint16_t, uint16_t);
} desc3;

uint32_t SDL_AttachVirtualJoystick(const desc3 *d) {
    state.attached++;
    state.product = d->product_id; state.nsensors = d->nsensors; state.nbuttons = d->nbuttons; state.naxes = d->naxes;
    state.userdata = d->userdata; state.update = d->Update; state.rumble = (void *)d->Rumble;
    return 42;
}
bool SDL_DetachVirtualJoystick(uint32_t id) { (void)id; state.detached++; return true; }
void *SDL_OpenJoystick(uint32_t id) { (void)id; state.opened++; return &joystick; }
void SDL_CloseJoystick(void *j) { (void)j; state.closed++; }
bool SDL_SetJoystickVirtualAxis(void *j, int axis, int16_t v) { (void)j; if (axis < 8) state.axes[axis] = v; return true; }
bool SDL_SetJoystickVirtualButton(void *j, int b, bool down) {
    (void)j;
    if (down) state.buttons |= 1u << b; else state.buttons &= ~(1u << b);
    return true;
}
bool SDL_SendJoystickVirtualSensorData(void *j, int32_t type, uint64_t ts, const float *data, int n) {
    (void)j; (void)ts;
    if (n == 3) memcpy(type == 1 ? state.accel : state.gyro, data, sizeof(float) * 3);
    state.sensor_events++;
    return true;
}
void fake_rumble(uint16_t lo, uint16_t hi) { ((bool (*)(void *, uint16_t, uint16_t))state.rumble)(state.userdata, lo, hi); }
#else
typedef struct {
    uint16_t version, type, naxes, nbuttons, nhats, vendor_id, product_id, padding;
    uint32_t button_mask, axis_mask;
    const char *name;
    void *userdata;
    void (*Update)(void *);
    void (*SetPlayerIndex)(void *, int);
    int (*Rumble)(void *, uint16_t, uint16_t);
} desc2;

int SDL_JoystickAttachVirtualEx(const desc2 *d) {
    state.attached++;
    state.product = d->product_id; state.nbuttons = d->nbuttons; state.naxes = d->naxes;
    state.userdata = d->userdata; state.update = d->Update; state.rumble = (void *)d->Rumble;
    return 0;                           // device index
}
int SDL_NumJoysticks(void) { return state.attached > state.detached ? 1 : 0; }
int32_t SDL_JoystickGetDeviceInstanceID(int i) { (void)i; return 7; }
int SDL_JoystickDetachVirtual(int i) { (void)i; state.detached++; return 0; }
void *SDL_JoystickOpen(int i) { (void)i; state.opened++; return &joystick; }
void SDL_JoystickClose(void *j) { (void)j; state.closed++; }
int32_t SDL_JoystickInstanceID(void *j) { (void)j; return 7; }
int SDL_JoystickSetVirtualAxis(void *j, int axis, int16_t v) { (void)j; if (axis < 8) state.axes[axis] = v; return 0; }
int SDL_JoystickSetVirtualButton(void *j, int b, uint8_t v) {
    (void)j;
    if (v) state.buttons |= 1u << b; else state.buttons &= ~(1u << b);
    return 0;
}
void fake_rumble(uint16_t lo, uint16_t hi) { ((int (*)(void *, uint16_t, uint16_t))state.rumble)(state.userdata, lo, hi); }
#endif
