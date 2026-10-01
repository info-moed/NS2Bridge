// NS2FF.plugin — a macOS ForceFeedback plug-in for Nintendo controllers driven by NS2 Bridge.
//
// NS2 Bridge registers this plug-in on the controller's HID device (IOCFPlugInTypes). When a game's
// SDL (IOKit joystick backend) asks macOS whether the controller supports force feedback, macOS loads
// this plug-in; SDL then reports rumble support and sends its rumble as a sine "effect". The plug-in
// turns effect magnitude changes into NS2 Bridge's rumble packets (UDP 127.0.0.1:26761), and NS2 Bridge
// plays them with the controller's real vibration format. Nothing inside the game is modified.
//
// Packet: "NS2R" u16 low u16 high u32 duration_ms(0 = until changed) u16 product_id
//         u64 device registry ID (so NS2 Bridge picks the exact controller) u8 rank (0xFF = unknown). LE.

#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <ForceFeedback/IOForceFeedbackLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <arpa/inet.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

// F4545CE5-BF5B-11D6-A4BB-0003933E3E3E: the ForceFeedback plug-in type (as used by Apple's own FF plug-ins).
#define NS2_FF_TYPE_ID CFUUIDGetConstantUUIDWithBytes(NULL, 0xF4, 0x54, 0x5C, 0xE5, 0xBF, 0x5B, 0x11, 0xD6, \
                                                      0xA4, 0xBB, 0x00, 0x03, 0x93, 0x3E, 0x3E, 0x3E)
// 3920F06A-59AC-42F3-9455-CD9629C27087: this plug-in's factory (also in Info.plist).
#define NS2_FF_FACTORY_ID CFUUIDGetConstantUUIDWithBytes(NULL, 0x39, 0x20, 0xF0, 0x6A, 0x59, 0xAC, 0x42, 0xF3, \
                                                         0x94, 0x55, 0xCD, 0x96, 0x29, 0xC2, 0x70, 0x87)

typedef struct {
    IUNKNOWN_C_GUTS;
    IOFORCEFEEDBACKDEVICE_FUNCS_100
} FFDeviceVtbl;

typedef struct NS2FF {
    IOCFPlugInInterface *pluginVtbl;   // interface 1: IOCFPlugInInterface
    FFDeviceVtbl *ffVtbl;              // interface 2: ForceFeedback device interface
    CFUUIDRef factoryID;
    UInt32 refCount;
    uint16_t productID;
    uint64_t deviceID;                 // IORegistry entry ID of the HID device
    UInt32 magnitude;                  // 0…10000, from the current effect
    UInt32 gain;                       // 0…10000, device gain
    int playing;
    int sock;
    struct sockaddr_in dest;
} NS2FF;

#define FROM_PLUGIN(p) ((NS2FF *)(p))
#define FROM_FF(p) ((NS2FF *)((char *)(p) - offsetof(NS2FF, ffVtbl)))

// ---------------------------------------------------------------- output

static void send_level(NS2FF *me) {
    if (me->sock < 0) return;
    double level = me->playing ? (double)me->magnitude / 10000.0 * (double)me->gain / 10000.0 : 0;
    if (level > 1) level = 1;
    uint16_t v = (uint16_t)(level * 65535.0 + 0.5);
    uint32_t ms = 0;                               // SDL stops the effect itself when its duration ends
    uint8_t p[23] = {'N', 'S', '2', 'R'};
    memcpy(p + 4, &v, 2);
    memcpy(p + 6, &v, 2);
    memcpy(p + 8, &ms, 4);
    memcpy(p + 12, &me->productID, 2);
    memcpy(p + 14, &me->deviceID, 8);
    p[22] = 0xFF;
    sendto(me->sock, p, sizeof p, 0, (const struct sockaddr *)&me->dest, sizeof me->dest);
}

static UInt32 magnitude_of(CFUUIDRef type, FFEFFECT *e) {
    if (!e || !e->lpvTypeSpecificParams) return 0;
    if (CFEqual(type, kFFEffectType_ConstantForce_ID) && e->cbTypeSpecificParams >= sizeof(FFCONSTANTFORCE)) {
        LONG m = ((FFCONSTANTFORCE *)e->lpvTypeSpecificParams)->lMagnitude;
        return (UInt32)(m < 0 ? -m : m);
    }
    if (e->cbTypeSpecificParams >= sizeof(FFPERIODIC))            // sine, square, triangle, saw…
        return ((FFPERIODIC *)e->lpvTypeSpecificParams)->dwMagnitude;
    return 0;
}

// ---------------------------------------------------------------- IUnknown (shared)

static ULONG ns2_addref(NS2FF *me) { return ++me->refCount; }

static ULONG ns2_release(NS2FF *me) {
    ULONG n = --me->refCount;
    if (n == 0) {
        me->playing = 0;
        send_level(me);
        if (me->sock >= 0) close(me->sock);
        CFUUIDRef f = me->factoryID;
        free(me->pluginVtbl);
        free(me->ffVtbl);
        free(me);
        CFPlugInRemoveInstanceForFactory(f);
        CFRelease(f);
    }
    return n;
}

static HRESULT ns2_query(NS2FF *me, REFIID iid, LPVOID *ppv) {
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, iid);
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(req, IUnknownUUID) || CFEqual(req, kIOCFPlugInInterfaceID)) {
        *ppv = &me->pluginVtbl; ns2_addref(me); r = S_OK;
    } else {
        // Any other request from the ForceFeedback framework is for the FF device interface.
        *ppv = &me->ffVtbl; ns2_addref(me); r = S_OK;
    }
    CFRelease(req);
    return r;
}

static HRESULT p_QueryInterface(void *self, REFIID iid, LPVOID *ppv) { return ns2_query(FROM_PLUGIN(self), iid, ppv); }
static ULONG p_AddRef(void *self) { return ns2_addref(FROM_PLUGIN(self)); }
static ULONG p_Release(void *self) { return ns2_release(FROM_PLUGIN(self)); }
static HRESULT f_QueryInterface(void *self, REFIID iid, LPVOID *ppv) { return ns2_query(FROM_FF(self), iid, ppv); }
static ULONG f_AddRef(void *self) { return ns2_addref(FROM_FF(self)); }
static ULONG f_Release(void *self) { return ns2_release(FROM_FF(self)); }

// ---------------------------------------------------------------- IOCFPlugInInterface

static uint16_t product_of(io_service_t service) {
    CFTypeRef v = IORegistryEntrySearchCFProperty(service, kIOServicePlane, CFSTR("ProductID"), NULL,
                                                  kIORegistryIterateRecursively | kIORegistryIterateParents);
    SInt32 pid = 0;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberSInt32Type, &pid);
    if (v) CFRelease(v);
    return (uint16_t)pid;
}

static IOReturn p_Probe(void *self, CFDictionaryRef props, io_service_t service, SInt32 *order) {
    (void)self; (void)props; (void)service;
    if (order) *order = 0;
    return kIOReturnSuccess;
}
static IOReturn p_Start(void *self, CFDictionaryRef props, io_service_t service) {
    (void)props;
    NS2FF *me = FROM_PLUGIN(self);
    if (service) { me->productID = product_of(service); IORegistryEntryGetRegistryEntryID(service, &me->deviceID); }
    return kIOReturnSuccess;
}
static IOReturn p_Stop(void *self) { (void)self; return kIOReturnSuccess; }

// ---------------------------------------------------------------- ForceFeedback device interface

static HRESULT f_GetVersion(void *self, ForceFeedbackVersion *v) {
    (void)self;
    if (!v) return FFERR_INVALIDPARAM;
    v->apiVersion.majorRev = 1; v->apiVersion.minorAndBugRev = 0;
    v->apiVersion.stage = finalStage; v->apiVersion.nonRelRev = 0;
    v->plugInVersion = v->apiVersion;
    return FF_OK;
}

static HRESULT f_InitializeTerminate(void *self, NumVersion api, io_object_t hid, boolean_t begin) {
    (void)api;
    NS2FF *me = FROM_FF(self);
    if (begin && hid) { me->productID = product_of(hid); IORegistryEntryGetRegistryEntryID(hid, &me->deviceID); }
    if (!begin) { me->playing = 0; send_level(me); }
    return FF_OK;
}

static HRESULT f_DestroyEffect(void *self, FFEffectDownloadID id) {
    (void)id;
    NS2FF *me = FROM_FF(self);
    me->playing = 0; send_level(me);
    return FF_OK;
}

static HRESULT f_DownloadEffect(void *self, CFUUIDRef type, FFEffectDownloadID *pid, FFEFFECT *e, FFEffectParameterFlag flags) {
    NS2FF *me = FROM_FF(self);
    if (pid && *pid == 0) *pid = 1;                               // a single effect slot is all rumble needs
    if (e && (flags & FFEP_TYPESPECIFICPARAMS)) me->magnitude = magnitude_of(type, e);
    if (e && (flags & FFEP_GAIN)) me->gain = e->dwGain ? e->dwGain : 10000;
    if (flags & FFEP_START) me->playing = 1;
    if (!(flags & FFEP_NODOWNLOAD) && (me->playing || (flags & FFEP_START))) send_level(me);
    return FF_OK;
}

static HRESULT f_Escape(void *self, FFEffectDownloadID id, FFEFFESCAPE *esc) {
    (void)self; (void)id; (void)esc;
    return FFERR_UNSUPPORTED;
}

static HRESULT f_GetEffectStatus(void *self, FFEffectDownloadID id, FFEffectStatusFlag *status) {
    (void)id;
    if (status) *status = FROM_FF(self)->playing ? FFEGES_PLAYING : 0;
    return FF_OK;
}

static HRESULT f_GetCapabilities(void *self, FFCAPABILITIES *c) {
    (void)self;
    if (!c) return FFERR_INVALIDPARAM;
    memset(c, 0, sizeof *c);
    c->ffSpecVer.majorRev = 1;
    c->supportedEffects = FFCAP_ET_CONSTANTFORCE | FFCAP_ET_SINE | FFCAP_ET_SQUARE | FFCAP_ET_TRIANGLE
                        | FFCAP_ET_SAWTOOTHUP | FFCAP_ET_SAWTOOTHDOWN;
    c->subType = FFCAP_ST_VIBRATION;
    c->numFfAxes = 2;
    c->ffAxes[0] = FFJOFS_X;
    c->ffAxes[1] = FFJOFS_Y;
    c->storageCapacity = 1;
    c->playbackCapacity = 1;
    c->driverVer.majorRev = 1;
    return FF_OK;
}

static HRESULT f_GetState(void *self, ForceFeedbackDeviceState *s) {
    if (!s) return FFERR_INVALIDPARAM;
    s->dwState = FFGFFS_ACTUATORSON | FFGFFS_POWERON | (FROM_FF(self)->playing ? 0 : FFGFFS_STOPPED);
    s->dwLoad = 0;
    return FF_OK;
}

static HRESULT f_SendCommand(void *self, FFCommandFlag cmd) {
    NS2FF *me = FROM_FF(self);
    if (cmd & (FFSFFC_RESET | FFSFFC_STOPALL | FFSFFC_PAUSE | FFSFFC_SETACTUATORSOFF)) { me->playing = 0; send_level(me); }
    return FF_OK;
}

static HRESULT f_SetProperty(void *self, FFProperty prop, void *value) {
    NS2FF *me = FROM_FF(self);
    if (prop == FFPROP_FFGAIN && value) { me->gain = *(UInt32 *)value; if (me->playing) send_level(me); }
    return FF_OK;
}

static HRESULT f_StartEffect(void *self, FFEffectDownloadID id, FFEffectStartFlag mode, UInt32 iterations) {
    (void)id; (void)mode; (void)iterations;
    NS2FF *me = FROM_FF(self);
    me->playing = 1; send_level(me);
    return FF_OK;
}

static HRESULT f_StopEffect(void *self, FFEffectDownloadID id) {
    (void)id;
    NS2FF *me = FROM_FF(self);
    me->playing = 0; send_level(me);
    return FF_OK;
}

// ---------------------------------------------------------------- factory

void *NS2FFFactory(CFAllocatorRef allocator, CFUUIDRef typeID);

void *NS2FFFactory(CFAllocatorRef allocator, CFUUIDRef typeID) {
    (void)allocator;
    if (!CFEqual(typeID, NS2_FF_TYPE_ID)) return NULL;
    NS2FF *me = calloc(1, sizeof *me);
    IOCFPlugInInterface *pv = calloc(1, sizeof *pv);
    FFDeviceVtbl *fv = calloc(1, sizeof *fv);
    if (!me || !pv || !fv) { free(me); free(pv); free(fv); return NULL; }

    pv->QueryInterface = p_QueryInterface; pv->AddRef = p_AddRef; pv->Release = p_Release;
    pv->version = 1; pv->revision = 0;
    pv->Probe = p_Probe; pv->Start = p_Start; pv->Stop = p_Stop;

    fv->QueryInterface = f_QueryInterface; fv->AddRef = f_AddRef; fv->Release = f_Release;
    fv->ForceFeedbackGetVersion = f_GetVersion; fv->InitializeTerminate = f_InitializeTerminate;
    fv->DestroyEffect = f_DestroyEffect; fv->DownloadEffect = f_DownloadEffect; fv->Escape = f_Escape;
    fv->GetEffectStatus = f_GetEffectStatus; fv->GetForceFeedbackCapabilities = f_GetCapabilities;
    fv->GetForceFeedbackState = f_GetState; fv->SendForceFeedbackCommand = f_SendCommand;
    fv->SetProperty = f_SetProperty; fv->StartEffect = f_StartEffect; fv->StopEffect = f_StopEffect;

    me->pluginVtbl = pv;
    me->ffVtbl = fv;
    me->refCount = 1;
    me->gain = 10000;
    me->factoryID = CFRetain(NS2_FF_FACTORY_ID);
    CFPlugInAddInstanceForFactory(me->factoryID);
    me->sock = socket(AF_INET, SOCK_DGRAM, 0);
    me->dest.sin_family = AF_INET;
    me->dest.sin_port = htons(26761);
    me->dest.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    return &me->pluginVtbl;
}
