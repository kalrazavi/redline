// Copyright (c) 2026 Ali Razavi. All rights reserved. Owned and controlled solely by Ali Razavi: no licence check, no remote control, no backdoor. Terms: see the LICENSE file.
//
// redline-fan: the one part of Redline that runs with administrator rights, so it is kept as small as possible.
// It understands exactly three words and nothing else:
//   status  print each fan's mode, speed and rated maximum (works without administrator rights)
//   max     run every fan at its own rated maximum, the top speed Apple built it for
//   auto    hand the fans back to macOS
// It never sets a speed below what macOS would choose, reads no files, takes no other input and talks to nothing but the Mac's sensor chip.
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef struct { char major, minor, build, reserved[1]; UInt16 release; } vers_t;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } plimit_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } info_t;
typedef struct { UInt32 key; vers_t vers; plimit_t pLimitData; info_t keyInfo; char result, status, data8; UInt32 data32; unsigned char bytes[32]; } smc_t;

static io_connect_t conn;
static int lastKr = 0, lastResult = 0;      // how the chip answered the most recent request, for honest error messages
#define VERSION 2
static UInt32 code(const char *s) { return ((UInt32)s[0] << 24) | ((UInt32)s[1] << 16) | ((UInt32)s[2] << 8) | (UInt32)s[3]; }
static int call(smc_t *in, smc_t *out) {
    size_t n = sizeof(smc_t); memset(out, 0, sizeof(smc_t));
    lastKr = IOConnectCallStructMethod(conn, 2, in, sizeof(smc_t), out, &n); lastResult = (unsigned char)out->result;
    return lastKr == kIOReturnSuccess && out->result == 0;
}
static int info(const char *key, info_t *ki) {
    smc_t in, out; memset(&in, 0, sizeof in); in.key = code(key); in.data8 = 9;
    if (!call(&in, &out) || out.keyInfo.dataSize == 0 || out.keyInfo.dataSize > 32) return 0;
    *ki = out.keyInfo; return 1;
}
static int readBytes(const char *key, info_t *ki, unsigned char *bytes) {
    if (!info(key, ki)) return 0;
    smc_t in, out; memset(&in, 0, sizeof in); in.key = code(key); in.keyInfo.dataSize = ki->dataSize; in.data8 = 5;
    if (!call(&in, &out)) return 0;
    memcpy(bytes, out.bytes, 32); return 1;
}
static int writeBytes(const char *key, info_t ki, const unsigned char *bytes) {
    smc_t in, out; memset(&in, 0, sizeof in); in.key = code(key); in.keyInfo.dataSize = ki.dataSize; in.data8 = 6;
    memcpy(in.bytes, bytes, ki.dataSize);
    return call(&in, &out);
}
// Fan speeds are stored either as a float or as a 14.2 fixed-point number, depending on the Mac.
static int readNumber(const char *key, double *v) {
    info_t ki; unsigned char b[32];
    if (!readBytes(key, &ki, b)) return 0;
    if (ki.dataType == code("flt ") && ki.dataSize == 4) { float f; memcpy(&f, b, 4); *v = f; return 1; }
    if (ki.dataType == code("fpe2") && ki.dataSize == 2) { *v = ((b[0] << 8) | b[1]) / 4.0; return 1; }
    if (ki.dataSize == 1) { *v = b[0]; return 1; }
    if (ki.dataSize == 2) { *v = (b[0] << 8) | b[1]; return 1; }
    return 0;
}
static int writeNumber(const char *key, double v) {
    info_t ki; unsigned char b[32]; memset(b, 0, sizeof b);
    if (!info(key, &ki)) return 0;
    if (ki.dataType == code("flt ") && ki.dataSize == 4) { float f = (float)v; memcpy(b, &f, 4); }
    else if (ki.dataType == code("fpe2") && ki.dataSize == 2) { unsigned r = (unsigned)(v * 4); b[0] = (r >> 8) & 0xff; b[1] = r & 0xff; }
    else if (ki.dataSize == 1) { b[0] = (unsigned char)v; }
    else if (ki.dataSize == 2) { unsigned r = (unsigned)v; b[0] = (r >> 8) & 0xff; b[1] = r & 0xff; }
    else return 0;
    return writeBytes(key, ki, b);
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "version")) { printf("%d\n", VERSION); return 0; }
    if (argc != 2 || (strcmp(argv[1], "status") && strcmp(argv[1], "max") && strcmp(argv[1], "auto"))) { fprintf(stderr, "usage: redline-fan status|max|auto\n"); return 2; }
    int want = !strcmp(argv[1], "max") ? 1 : (!strcmp(argv[1], "auto") ? 0 : -1);
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn) != kIOReturnSuccess) { fprintf(stderr, "cannot reach the sensor chip\n"); return 1; }
    double count = 0; if (!readNumber("FNum", &count) || count < 1 || count > 6) { fprintf(stderr, "no fans found\n"); return 1; }
    if (want >= 0 && geteuid() == 0) { setgid(0); setuid(0); }      // act fully as the system, not half as the user
    if (want >= 0 && geteuid() != 0) { fprintf(stderr, "needs administrator rights: run 'Enable fan control' once\n"); return 3; }
    int ok = 1;
    for (int i = 0; i < (int)count; i++) {
        char md[5], tg[5], mx[5], ac[5]; snprintf(md, 5, "F%dMd", i); snprintf(tg, 5, "F%dTg", i); snprintf(mx, 5, "F%dMx", i); snprintf(ac, 5, "F%dAc", i);
        double top = 0, now = 0, mode = 0;
        if (!readNumber(mx, &top) || top < 1000 || top > 12000) { fprintf(stderr, "fan %d: no rated maximum, left alone\n", i); ok = 0; continue; }
        if (want == 1) {
            // The target is the fan's own rated maximum as reported by the Mac (never a number made up here, never above it).
            int okMode = writeNumber(md, 1), krM = lastKr, rsM = lastResult;
            int okTarget = writeNumber(tg, top), krT = lastKr, rsT = lastResult;
            // The chip takes a moment to accept a new target, so look again for up to two seconds before judging.
            double set = 0, m = 0; int good = 0;
            for (int t = 0; t < 14 && !good; t++) { usleep(150000); readNumber(tg, &set); readNumber(md, &m); good = m > 0 && set <= top + 1 && set >= top - 60; }
            if (!good) {      // never leave a fan held at a speed nobody chose: hand it straight back to macOS
                writeNumber(md, 0); ok = 0;
                fprintf(stderr, "fan %d: maximum not accepted, returned to automatic (mode write %d kr=%x r=%02x, target write %d kr=%x r=%02x, read back mode %.0f target %.0f of %.0f)\n",
                        i, okMode, krM, rsM, okTarget, krT, rsT, m, set, top);
            }
        }
        if (want == 0) { if (!writeNumber(md, 0)) { fprintf(stderr, "fan %d: could not return to automatic\n", i); ok = 0; } }
        readNumber(ac, &now); readNumber(md, &mode);
        printf("fan %d mode %s now %.0f max %.0f\n", i, mode > 0 ? "max" : "auto", now, top);
    }
    return ok ? 0 : 1;
}
