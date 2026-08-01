/*
 * smc — AppleSMC (System Management Controller) okuma/yazma yardımcısı
 * Kullanım:
 *   smc list                    — tüm anahtarları listele
 *   smc read <KEY>              — anahtarı oku ve değerini yazdır
 *   smc write <KEY> <VALUE>     — anahtara değer yaz (root gerekir)
 *
 * Fan anahtarları (fan 0/1):
 *   FNum   okunur, fan sayısı
 *   F0Md   yazma modu: 0=auto (sistem), 1=manual
 *   F0Mn   minimum rpm (flt)
 *   F0Mx   maksimum rpm (flt)
 *   F0Tg   hedef rpm (flt) — yalnızca F0Md=1 iken etkilidir
 *   F0Ac   gerçek rpm (fpe2)
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <IOKit/IOKitLib.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9

typedef struct {
    char major, minor, build, reserved[1];
    UInt16 release;
} SMCKeyData_vers_t;

typedef struct {
    UInt16 version;
    UInt16 length;
    UInt32 cpuPLimit;
    UInt32 gpuPLimit;
    UInt32 memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    UInt32 dataSize;
    UInt32 dataType;
    char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef char SMCBytes_t[32];

typedef struct {
    UInt32 key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    UInt32 data32;
    SMCBytes_t bytes;
} SMCKeyData_t;

static io_connect_t conn = 0;

static uint32_t str_key(const char *s) {
    uint32_t k = 0;
    for (int i = 0; i < 4 && s[i]; i++) {
        k = (k << 8) | (unsigned char)s[i];
    }
    return k;
}

static void key_str(char *out, uint32_t k) {
    out[0] = (char)(k >> 24);
    out[1] = (char)(k >> 16);
    out[2] = (char)(k >> 8);
    out[3] = (char)(k);
    out[4] = '\0';
}

static kern_return_t smc_call(int index, SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t outSize = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(conn, index, in, sizeof(SMCKeyData_t), out, &outSize);
}

static kern_return_t smc_read_info(const char *key, SMCKeyData_keyInfo_t *info) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = str_key(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t r = smc_call(KERNEL_INDEX_SMC, &in, &out);
    if (r == kIOReturnSuccess)
        *info = out.keyInfo;
    return r;
}

static kern_return_t smc_read_data(const char *key, SMCBytes_t bytes, UInt32 size) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = str_key(key);
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_READ_BYTES;
    kern_return_t r = smc_call(KERNEL_INDEX_SMC, &in, &out);
    if (r == kIOReturnSuccess)
        memcpy(bytes, out.bytes, sizeof(out.bytes));
    return r;
}

static kern_return_t smc_write_data(const char *key, SMCBytes_t bytes, UInt32 size) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = str_key(key);
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = size;
    memcpy(in.bytes, bytes, sizeof(in.bytes));
    return smc_call(KERNEL_INDEX_SMC, &in, &out);
}

static const char *type_name(uint32_t t) {
    static char buf[5];
    key_str(buf, t);
    return buf;
}

static double decode_value(uint32_t type, SMCBytes_t d, UInt32 size) {
    char t[5];
    key_str(t, type);
    if (strcmp(t, "fpe2") == 0 && size >= 2) {
        unsigned char a = d[0], b = d[1];
        return (double)(((uint16_t)a << 8) | b) / 4.0;
    }
    if (strcmp(t, "fpe4") == 0 && size >= 4) {
        uint32_t v = ((uint32_t)(unsigned char)d[0] << 24) |
                     ((uint32_t)(unsigned char)d[1] << 16) |
                     ((uint32_t)(unsigned char)d[2] << 8) |
                     (unsigned char)d[3];
        return (double)v / 65536.0;
    }
    if (strcmp(t, "flt ") == 0 && size >= 4) {
        float f;
        memcpy(&f, d, 4);
        return (double)f;
    }
    if (strncmp(t, "sp", 2) == 0) {
        int32_t v;
        if (size >= 2)
            v = (int16_t)(((unsigned char)d[0] << 8) | (unsigned char)d[1]);
        else
            v = (int8_t)d[0];
        double scale = 1.0;
        if (t[3] >= '0' && t[3] <= '9') {
            int frac = t[3] - '0';
            scale = 1.0 / (double)(1 << frac);
        }
        return (double)v * scale;
    }
    if (size == 1) {
        if (strncmp(t, "si", 2) == 0) return (double)(int8_t)d[0];
        return (double)d[0];
    }
    if (size == 2) {
        uint16_t v = (uint16_t)(((unsigned char)d[0] << 8) | (unsigned char)d[1]);
        if (strncmp(t, "si", 2) == 0) return (double)(int16_t)v;
        return (double)v;
    }
    if (size == 4) {
        uint32_t v = ((uint32_t)(unsigned char)d[0] << 24) |
                     ((uint32_t)(unsigned char)d[1] << 16) |
                     ((uint32_t)(unsigned char)d[2] << 8) |
                     (unsigned char)d[3];
        if (strncmp(t, "si", 2) == 0) return (double)(int32_t)v;
        return (double)v;
    }
    return 0;
}

static void encode_value(uint32_t type, double v, SMCBytes_t d, UInt32 size) {
    char t[5];
    key_str(t, type);
    memset(d, 0, 32);
    if (strcmp(t, "fpe2") == 0 && size >= 2) {
        uint16_t x = (uint16_t)(v * 4.0);
        d[0] = x >> 8;
        d[1] = x & 0xff;
    } else if (strcmp(t, "fpe4") == 0 && size >= 4) {
        uint32_t x = (uint32_t)(v * 65536.0);
        d[0] = x >> 24; d[1] = x >> 16; d[2] = x >> 8; d[3] = x;
    } else if (strcmp(t, "flt ") == 0 && size >= 4) {
        float f = (float)v;
        memcpy(d, &f, 4);
    } else if (size == 1) {
        d[0] = (uint8_t)v;
    } else if (size == 2) {
        uint16_t x = (uint16_t)v;
        d[0] = x >> 8;
        d[1] = x & 0xff;
    } else if (size == 4) {
        uint32_t x = (uint32_t)v;
        d[0] = x >> 24; d[1] = x >> 16; d[2] = x >> 8; d[3] = x;
    }
}

static int connect_smc(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == 0) return -1;
    kern_return_t r = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    return r == kIOReturnSuccess ? 0 : -1;
}

static int cmd_read(const char *key) {
    SMCKeyData_keyInfo_t info;
    if (smc_read_info(key, &info) != kIOReturnSuccess) {
        fprintf(stderr, "smc: anahtar okunamadı: %s\n", key);
        return 1;
    }
    SMCBytes_t data;
    if (smc_read_data(key, data, info.dataSize) != kIOReturnSuccess) {
        fprintf(stderr, "smc: veri okunamadı: %s\n", key);
        return 1;
    }
    printf("%s=%g\n", key, decode_value(info.dataType, data, info.dataSize));
    return 0;
}

static int cmd_write(const char *key, const char *val) {
    SMCKeyData_keyInfo_t info;
    if (smc_read_info(key, &info) != kIOReturnSuccess) {
        fprintf(stderr, "smc: anahtar bulunamadı: %s\n", key);
        return 1;
    }
    SMCBytes_t data;
    encode_value(info.dataType, atof(val), data, info.dataSize);
    if (smc_write_data(key, data, info.dataSize) != kIOReturnSuccess) {
        fprintf(stderr, "smc: yazma başarısız (root gerekli): %s\n", key);
        return 1;
    }
    printf("ok: %s=%s\n", key, val);
    return 0;
}

static int cmd_list(void) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(KERNEL_INDEX_SMC, &in, &out) != kIOReturnSuccess) {
        fprintf(stderr, "smc: anahtar sayısı okunamadı\n");
        return 1;
    }
    uint32_t count = out.keyInfo.dataSize;
    printf("anahtar sayısı: %u\n", count);
    for (uint32_t i = 0; i < count && i < 40; i++) {
        memset(&in, 0, sizeof(in));
        memset(&out, 0, sizeof(out));
        in.data8 = SMC_CMD_READ_INDEX;
        in.data32 = i;
        if (smc_call(KERNEL_INDEX_SMC, &in, &out) != kIOReturnSuccess)
            continue;
        char k[5];
        k[0] = out.bytes[0]; k[1] = out.bytes[1]; k[2] = out.bytes[2]; k[3] = out.bytes[3]; k[4] = '\0';
        SMCKeyData_keyInfo_t info;
        if (smc_read_info(k, &info) != kIOReturnSuccess)
            continue;
        SMCBytes_t data;
        if (smc_read_data(k, data, info.dataSize) != kIOReturnSuccess)
            continue;
        printf("  %s type=%s size=%u val=%g\n", k, type_name(info.dataType),
               info.dataSize, decode_value(info.dataType, data, info.dataSize));
    }
    return 0;
}

static int cmd_dump(const char *key) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = str_key(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t r1 = smc_call(KERNEL_INDEX_SMC, &in, &out);
    uint32_t size = out.keyInfo.dataSize;
    uint32_t type = out.keyInfo.dataType;
    printf("key=%s\n", key);
    printf("  read_index rc=%u result=%d status=%d\n", r1,
           (int)(signed char)out.result, (int)(signed char)out.status);
    printf("  keyInfo: dataSize=%u dataType=%s dataAttributes=%d\n",
           size, type_name(type), (int)(signed char)out.keyInfo.dataAttributes);

    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = str_key(key);
    in.data8 = SMC_CMD_READ_BYTES;
    in.keyInfo.dataSize = size;
    kern_return_t r2 = smc_call(KERNEL_INDEX_SMC, &in, &out);
    printf("  read_bytes rc=%u result=%d status=%d\n", r2,
           (int)(signed char)out.result, (int)(signed char)out.status);
    printf("  bytes: ");
    for (int i = 0; i < 8; i++)
        printf("%02x ", (unsigned char)out.bytes[i]);
    printf("\n  decoded=%g\n", decode_value(type, out.bytes, size));
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "kullanım: smc list | smc read <KEY> | smc write <KEY> <VALUE>\n");
        return 1;
    }
    if (connect_smc() != 0) {
        fprintf(stderr, "smc: AppleSMC bağlantısı kurulamadı\n");
        return 1;
    }
    const char *cmd = argv[1];
    if (strcmp(cmd, "list") == 0)
        return cmd_list();
    if (strcmp(cmd, "read") == 0 && argc == 3)
        return cmd_read(argv[2]);
    if (strcmp(cmd, "dump") == 0 && argc == 3)
        return cmd_dump(argv[2]);
    if (strcmp(cmd, "write") == 0 && argc == 4)
        return cmd_write(argv[2], argv[3]);
    fprintf(stderr, "kullanım: smc list | smc read <KEY> | smc dump <KEY> | smc write <KEY> <VALUE>\n");
    return 1;
}
