#ifndef CHIDSPI_H
#define CHIDSPI_H

// Hand-declared private SPI for reading the Apple Silicon SPU accelerometer.
// These symbols live in IOKit but are NOT in any public header. Verified
// against macOS 26.x on Mac14,5. Undocumented and version-fragile.

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service,
                                                 int64_t type, int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

// Confirmed by spike: event type 12, field = (type << 16) | axis, axes X=0 Y=1 Z=2.
#define kIOHIDEventTypeAccelerometer 12

static inline int32_t HIDAccelField(int32_t axis) {
    return (int32_t)((kIOHIDEventTypeAccelerometer << 16) | axis);
}

// IOHIDEventRef is a CF type (confirmed: CFRelease works on it), but Swift bans
// CFRelease. Wrap it so Swift can free copied events without leaking.
static inline void HIDEventRelease(IOHIDEventRef event) {
    if (event) CFRelease((CFTypeRef)event);
}

#endif /* CHIDSPI_H */
