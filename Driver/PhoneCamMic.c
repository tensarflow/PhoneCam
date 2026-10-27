// PhoneCam Microphone: a Core Audio server plug-in (HAL driver) with two devices.
//
//   "PhoneCam Microphone"  visible input device that video apps record from
//   "PhoneCam Mic Feed"    hidden output device the PhoneCam app plays the phone's mic into
//
// Both devices share one clock and one ring buffer: whatever is written to the feed at
// sample time T is read back from the microphone at sample time T. Sample times that
// were never written (or were overwritten) read as silence.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

// MARK: - Constants

// Keep in sync with MicFeed.swift.
#define kMicDeviceUID   "PhoneCamMic_UID"
#define kFeedDeviceUID  "PhoneCamMicFeed_UID"

enum {
    kObjectID_PlugIn     = kAudioObjectPlugInObject,
    kObjectID_MicDevice  = 2,
    kObjectID_MicStream  = 3,
    kObjectID_FeedDevice = 4,
    kObjectID_FeedStream = 5,
};

static const Float64 kSampleRate = 48000.0;
static const UInt32 kChannels = 2;
// Ring buffer length and zero-time-stamp period, in frames (~341 ms).
#define kRingFrames 16384

// MARK: - State

static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;

static UInt32 gIOCount[2] = {0, 0};     // [mic, feed] clients doing IO
static Float64 gHostTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gNumberTimeStamps = 0;

static os_unfair_lock gRingLock = OS_UNFAIR_LOCK_INIT;
static Float32 gRing[kRingFrames * 2];
static Float64 gFeedWrittenUpTo = 0;    // sample time just past the last frame the feed wrote

static bool isDevice(AudioObjectID id) { return id == kObjectID_MicDevice || id == kObjectID_FeedDevice; }
static bool isStream(AudioObjectID id) { return id == kObjectID_MicStream || id == kObjectID_FeedStream; }
static bool isMic(AudioObjectID id) { return id == kObjectID_MicDevice || id == kObjectID_MicStream; }
static AudioObjectID streamOf(AudioObjectID device) {
    return device == kObjectID_MicDevice ? kObjectID_MicStream : kObjectID_FeedStream;
}
static AudioObjectID deviceOf(AudioObjectID stream) {
    return stream == kObjectID_MicStream ? kObjectID_MicDevice : kObjectID_FeedDevice;
}

static AudioStreamBasicDescription streamFormat(void) {
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = kSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = sizeof(Float32) * kChannels;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(Float32) * kChannels;
    format.mChannelsPerFrame = kChannels;
    format.mBitsPerChannel = sizeof(Float32) * 8;
    return format;
}

static bool isOurFormat(const AudioStreamBasicDescription* format) {
    return format->mSampleRate == kSampleRate && format->mFormatID == kAudioFormatLinearPCM
        && (format->mFormatFlags & kAudioFormatFlagIsFloat) && format->mChannelsPerFrame == kChannels;
}

// MARK: - Property helpers

#define RETURN_SCALAR(type, value)                                                  \
    do {                                                                            \
        if (outData) {                                                              \
            if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
            *(type*)outData = (value);                                              \
        }                                                                           \
        *outDataSize = sizeof(type);                                                \
        return 0;                                                                   \
    } while (0)

static OSStatus returnIDs(const AudioObjectID* ids, UInt32 count, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (outData) {
        UInt32 fit = inDataSize / sizeof(AudioObjectID);
        if (fit < count) count = fit;
        memcpy(outData, ids, count * sizeof(AudioObjectID));
    }
    *outDataSize = count * sizeof(AudioObjectID);
    return 0;
}

// One function answers both "how big" (outData == NULL) and "what value" queries.
static OSStatus getProperty(AudioObjectID object, const AudioObjectPropertyAddress* address,
                            UInt32 qualifierSize, const void* qualifier,
                            UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    const AudioObjectPropertySelector selector = address->mSelector;

    if (object == kObjectID_PlugIn) {
        switch (selector) {
        case kAudioObjectPropertyBaseClass: RETURN_SCALAR(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_SCALAR(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: RETURN_SCALAR(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RETURN_SCALAR(CFStringRef, CFSTR("PhoneCam"));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            AudioObjectID devices[] = {kObjectID_MicDevice, kObjectID_FeedDevice};
            return returnIDs(devices, 2, inDataSize, outDataSize, outData);
        }
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyClockDeviceList:
            return returnIDs(NULL, 0, inDataSize, outDataSize, outData);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID found = kAudioObjectUnknown;
            if (qualifier && qualifierSize == sizeof(CFStringRef)) {
                CFStringRef uid = *(const CFStringRef*)qualifier;
                if (CFStringCompare(uid, CFSTR(kMicDeviceUID), 0) == kCFCompareEqualTo) found = kObjectID_MicDevice;
                if (CFStringCompare(uid, CFSTR(kFeedDeviceUID), 0) == kCFCompareEqualTo) found = kObjectID_FeedDevice;
            }
            RETURN_SCALAR(AudioObjectID, found);
        }
        case kAudioPlugInPropertyResourceBundle: RETURN_SCALAR(CFStringRef, CFSTR(""));
        default: return kAudioHardwareUnknownPropertyError;
        }
    }

    if (isDevice(object)) {
        const bool mic = isMic(object);
        const bool inOurScope = address->mScope == kAudioObjectPropertyScopeGlobal
            || address->mScope == (mic ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput);
        switch (selector) {
        case kAudioObjectPropertyBaseClass: RETURN_SCALAR(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_SCALAR(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: RETURN_SCALAR(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName:
            RETURN_SCALAR(CFStringRef, mic ? CFSTR("PhoneCam Microphone") : CFSTR("PhoneCam Mic Feed"));
        case kAudioObjectPropertyManufacturer: RETURN_SCALAR(CFStringRef, CFSTR("PhoneCam"));
        case kAudioDevicePropertyDeviceUID:
            RETURN_SCALAR(CFStringRef, mic ? CFSTR(kMicDeviceUID) : CFSTR(kFeedDeviceUID));
        case kAudioDevicePropertyModelUID: RETURN_SCALAR(CFStringRef, CFSTR("PhoneCamMic_ModelUID"));
        case kAudioDevicePropertyTransportType: RETURN_SCALAR(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: {
            AudioObjectID self = object;
            return returnIDs(&self, 1, inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyClockDomain: RETURN_SCALAR(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_SCALAR(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = gIOCount[mic ? 0 : 1] > 0;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_SCALAR(UInt32, running);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            RETURN_SCALAR(UInt32, mic && address->mScope == kAudioObjectPropertyScopeInput);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_SCALAR(UInt32, 0);
        case kAudioDevicePropertyLatency: RETURN_SCALAR(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: RETURN_SCALAR(UInt32, 0);
        case kAudioDevicePropertyClockIsStable: RETURN_SCALAR(UInt32, 1);
        case kAudioDevicePropertyIsHidden: RETURN_SCALAR(UInt32, mic ? 0 : 1);
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_SCALAR(UInt32, kRingFrames);
        case kAudioDevicePropertyNominalSampleRate: RETURN_SCALAR(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange range = {kSampleRate, kSampleRate};
            RETURN_SCALAR(AudioValueRange, range);
        }
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            AudioObjectID stream = streamOf(object);
            return returnIDs(&stream, inOurScope ? 1 : 0, inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyControlList:
            return returnIDs(NULL, 0, inDataSize, outDataSize, outData);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32 size = 2 * sizeof(UInt32);
            if (outData) {
                if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
                ((UInt32*)outData)[0] = 1;
                ((UInt32*)outData)[1] = 2;
            }
            *outDataSize = size;
            return 0;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription));
            if (outData) {
                if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
                AudioChannelLayout* layout = outData;
                memset(layout, 0, size);
                layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                layout->mNumberChannelDescriptions = kChannels;
                layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            }
            *outDataSize = size;
            return 0;
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
    }

    if (isStream(object)) {
        const bool mic = isMic(object);
        switch (selector) {
        case kAudioObjectPropertyBaseClass: RETURN_SCALAR(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_SCALAR(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: RETURN_SCALAR(AudioObjectID, deviceOf(object));
        case kAudioObjectPropertyOwnedObjects: return returnIDs(NULL, 0, inDataSize, outDataSize, outData);
        case kAudioStreamPropertyIsActive: RETURN_SCALAR(UInt32, 1);
        case kAudioStreamPropertyDirection: RETURN_SCALAR(UInt32, mic ? 1 : 0);
        case kAudioStreamPropertyTerminalType:
            RETURN_SCALAR(UInt32, mic ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: RETURN_SCALAR(UInt32, 1);
        case kAudioStreamPropertyLatency: RETURN_SCALAR(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: RETURN_SCALAR(AudioStreamBasicDescription, streamFormat());
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription ranged = {streamFormat(), {kSampleRate, kSampleRate}};
            RETURN_SCALAR(AudioStreamRangedDescription, ranged);
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

// MARK: - Driver interface

static HRESULT PhoneCamMic_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG PhoneCamMic_AddRef(void* inDriver);
static ULONG PhoneCamMic_Release(void* inDriver);

static OSStatus PhoneCamMic_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    gHost = inHost;
    struct mach_timebase_info timebase;
    mach_timebase_info(&timebase);
    Float64 hostTicksPerSecond = 1.0e9 * (Float64)timebase.denom / (Float64)timebase.numer;
    gHostTicksPerFrame = hostTicksPerSecond / kSampleRate;
    return 0;
}

static OSStatus PhoneCamMic_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc,
                                         const AudioServerPlugInClientInfo* client, AudioObjectID* outID) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus PhoneCamMic_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID device) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus PhoneCamMic_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device,
                                            const AudioServerPlugInClientInfo* client) {
    return isDevice(device) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus PhoneCamMic_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device,
                                               const AudioServerPlugInClientInfo* client) {
    return isDevice(device) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus PhoneCamMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID device,
                                                             UInt64 action, void* info) {
    return 0;
}

static OSStatus PhoneCamMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID device,
                                                           UInt64 action, void* info) {
    return 0;
}

static Boolean PhoneCamMic_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t client,
                                       const AudioObjectPropertyAddress* address) {
    UInt32 size = 0;
    return getProperty(object, address, 0, NULL, 0, &size, NULL) == 0;
}

static OSStatus PhoneCamMic_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t client,
                                               const AudioObjectPropertyAddress* address, Boolean* outIsSettable) {
    if (!PhoneCamMic_HasProperty(d, object, client, address)) return kAudioHardwareUnknownPropertyError;
    // The rate and format can be "set" to the one value we support, which some apps insist on.
    *outIsSettable = (isDevice(object) && address->mSelector == kAudioDevicePropertyNominalSampleRate)
        || (isStream(object) && (address->mSelector == kAudioStreamPropertyVirtualFormat
                                 || address->mSelector == kAudioStreamPropertyPhysicalFormat));
    return 0;
}

static OSStatus PhoneCamMic_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t client,
                                                const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
                                                const void* qualifier, UInt32* outDataSize) {
    return getProperty(object, address, qualifierSize, qualifier, 0, outDataSize, NULL);
}

static OSStatus PhoneCamMic_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t client,
                                            const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
                                            const void* qualifier, UInt32 inDataSize, UInt32* outDataSize,
                                            void* outData) {
    return getProperty(object, address, qualifierSize, qualifier, inDataSize, outDataSize, outData);
}

static OSStatus PhoneCamMic_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t client,
                                            const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
                                            const void* qualifier, UInt32 inDataSize, const void* inData) {
    if (isDevice(object) && address->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *(const Float64*)inData == kSampleRate ? 0 : kAudioHardwareUnsupportedOperationError;
    }
    if (isStream(object) && (address->mSelector == kAudioStreamPropertyVirtualFormat
                             || address->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        return isOurFormat(inData) ? 0 : kAudioDeviceUnsupportedFormatError;
    }
    return PhoneCamMic_HasProperty(d, object, client, address) ? kAudioHardwareUnsupportedOperationError
                                                                : kAudioHardwareUnknownPropertyError;
}

static void notifyRunningChanged(AudioObjectID device) {
    AudioObjectPropertyAddress address = {kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    if (gHost) gHost->PropertiesChanged(gHost, device, 1, &address);
}

static OSStatus PhoneCamMic_StartIO(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client) {
    if (!isDevice(device)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    UInt32* count = &gIOCount[isMic(device) ? 0 : 1];
    // Both devices tick on one shared clock, anchored when the first of them starts.
    if (gIOCount[0] + gIOCount[1] == 0) {
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
    }
    bool first = (*count)++ == 0;
    pthread_mutex_unlock(&gStateMutex);
    if (first) notifyRunningChanged(device);
    return 0;
}

static OSStatus PhoneCamMic_StopIO(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client) {
    if (!isDevice(device)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    UInt32* count = &gIOCount[isMic(device) ? 0 : 1];
    bool last = *count > 0 && --(*count) == 0;
    pthread_mutex_unlock(&gStateMutex);
    if (last && device == kObjectID_FeedDevice) {
        os_unfair_lock_lock(&gRingLock);
        memset(gRing, 0, sizeof(gRing));
        gFeedWrittenUpTo = 0;
        os_unfair_lock_unlock(&gRingLock);
    }
    if (last) notifyRunningChanged(device);
    return 0;
}

static OSStatus PhoneCamMic_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client,
                                             Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    pthread_mutex_lock(&gStateMutex);
    Float64 hostTicksPerRing = gHostTicksPerFrame * (Float64)kRingFrames;
    UInt64 nextZero = gAnchorHostTime + (UInt64)((Float64)(gNumberTimeStamps + 1) * hostTicksPerRing);
    if (nextZero <= mach_absolute_time()) gNumberTimeStamps++;
    *outSampleTime = (Float64)(gNumberTimeStamps * kRingFrames);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gNumberTimeStamps * hostTicksPerRing);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus PhoneCamMic_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client,
                                              UInt32 operation, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    *outWillDo = (device == kObjectID_MicDevice && operation == kAudioServerPlugInIOOperationReadInput)
        || (device == kObjectID_FeedDevice && operation == kAudioServerPlugInIOOperationWriteMix);
    *outWillDoInPlace = true;
    return 0;
}

static OSStatus PhoneCamMic_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client,
                                             UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle) {
    return 0;
}

static OSStatus PhoneCamMic_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, AudioObjectID stream,
                                          UInt32 client, UInt32 operation, UInt32 frames,
                                          const AudioServerPlugInIOCycleInfo* cycle, void* mainBuffer,
                                          void* secondaryBuffer) {
    Float32* buffer = mainBuffer;
    if (device == kObjectID_FeedDevice && operation == kAudioServerPlugInIOOperationWriteMix) {
        Float64 start = cycle->mOutputTime.mSampleTime;
        os_unfair_lock_lock(&gRingLock);
        for (UInt32 frame = 0; frame < frames; frame++) {
            UInt64 slot = ((UInt64)(start + frame)) % kRingFrames;
            gRing[slot * 2] = buffer[frame * 2];
            gRing[slot * 2 + 1] = buffer[frame * 2 + 1];
        }
        if (start + frames > gFeedWrittenUpTo) gFeedWrittenUpTo = start + frames;
        os_unfair_lock_unlock(&gRingLock);
    } else if (device == kObjectID_MicDevice && operation == kAudioServerPlugInIOOperationReadInput) {
        Float64 start = cycle->mInputTime.mSampleTime;
        os_unfair_lock_lock(&gRingLock);
        Float64 written = gFeedWrittenUpTo;
        for (UInt32 frame = 0; frame < frames; frame++) {
            Float64 time = start + frame;
            // Only frames the feed actually wrote, and that haven't been overwritten since, are real.
            if (time < written && time >= written - kRingFrames) {
                UInt64 slot = ((UInt64)time) % kRingFrames;
                buffer[frame * 2] = gRing[slot * 2];
                buffer[frame * 2 + 1] = gRing[slot * 2 + 1];
            } else {
                buffer[frame * 2] = 0;
                buffer[frame * 2 + 1] = 0;
            }
        }
        os_unfair_lock_unlock(&gRingLock);
    }
    return 0;
}

static OSStatus PhoneCamMic_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client,
                                           UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle) {
    return 0;
}

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,
    PhoneCamMic_QueryInterface,
    PhoneCamMic_AddRef,
    PhoneCamMic_Release,
    PhoneCamMic_Initialize,
    PhoneCamMic_CreateDevice,
    PhoneCamMic_DestroyDevice,
    PhoneCamMic_AddDeviceClient,
    PhoneCamMic_RemoveDeviceClient,
    PhoneCamMic_PerformDeviceConfigurationChange,
    PhoneCamMic_AbortDeviceConfigurationChange,
    PhoneCamMic_HasProperty,
    PhoneCamMic_IsPropertySettable,
    PhoneCamMic_GetPropertyDataSize,
    PhoneCamMic_GetPropertyData,
    PhoneCamMic_SetPropertyData,
    PhoneCamMic_StartIO,
    PhoneCamMic_StopIO,
    PhoneCamMic_GetZeroTimeStamp,
    PhoneCamMic_WillDoIOOperation,
    PhoneCamMic_BeginIOOperation,
    PhoneCamMic_DoIOOperation,
    PhoneCamMic_EndIOOperation,
};
static AudioServerPlugInDriverInterface* gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef gDriverRef = &gDriverInterfacePtr;

static HRESULT PhoneCamMic_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    bool supported = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!supported) return E_NOINTERFACE;
    pthread_mutex_lock(&gStateMutex);
    gRefCount++;
    pthread_mutex_unlock(&gStateMutex);
    *outInterface = gDriverRef;
    return S_OK;
}

static ULONG PhoneCamMic_AddRef(void* inDriver) {
    pthread_mutex_lock(&gStateMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG PhoneCamMic_Release(void* inDriver) {
    pthread_mutex_lock(&gStateMutex);
    ULONG count = gRefCount > 0 ? --gRefCount : 0;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

// MARK: - Factory (named in Info.plist's CFPlugInFactories)

__attribute__((visibility("default")))
void* PhoneCamMic_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriverRef;
}
