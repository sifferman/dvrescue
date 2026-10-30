/*  Copyright (c) MIPoPS. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-3-Clause license that can
 *  be found in the LICENSE.txt file in the root of the source tree.
 */

#include "Common/QtkitCtlWrapper.h"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <deque>
#include <stdexcept>
#include <vector>
#import <Foundation/Foundation.h>
#import <QTKit/QTKit.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/avc/IOFireWireAVCLib.h>

using namespace std;

static const UInt8 AvcControlCommand = 0x00;
static const UInt8 AvcStatusCommand = 0x01;
static const UInt8 AvcStableResponse = 0x0C;
static const UInt8 AvcInTransitionResponse = 0x0B;
static const UInt8 TapeRecorderSubunit = 0x20;
static const UInt8 TransportStateOpcode = 0xD0;
static const UInt8 LoadMediumOpcode = 0xC1;
static const UInt8 RecordOpcode = 0xC2;
static const UInt8 PlayOpcode = 0xC3;
static const UInt8 WindOpcode = 0xC4;
static const UInt8 PlayForwardOperand = 0x38;
static const UInt8 PlayForwardPauseOperand = 0x7D;
static const UInt8 PlayReverseOperand = 0x48;
static const UInt8 PlayReversePauseOperand = 0x6D;
static const UInt8 PlayFastestForwardOperand = 0x3F;
static const UInt8 PlayFastestReverseOperand = 0x4F;
static const UInt8 PlaySlowestForwardOperand = 0x31;
static const UInt8 PlaySlowestReverseOperand = 0x41;
static const UInt8 PlayNextFrameOperand = 0x30;
static const UInt8 PlayPreviousFrameOperand = 0x40;
static const UInt8 PlayForwardAlternativeOperand = 0x75;
static const UInt8 PlayReverseAlternativeOperand = 0x65;
static const UInt8 WindStopOperand = 0x60;
static const UInt8 WindRewindOperand = 0x65;
static const UInt8 WindFastForwardOperand = 0x75;
static const UInt8 SpeedStepCount = 0x07;
static const double SecondsBetweenTransportPolls = 0.25;
static const double SecondsToWaitForPlaybackToBegin = 10.0;

struct TransportPosition
{
    playback_mode Mode;
    float Speed;
    const char* Description;
};

static float ConvertPlayOperandToSpeed(UInt8 Operand)
{
    if (Operand == PlayForwardOperand || Operand == PlayForwardAlternativeOperand)
        return 1.0f;
    if (Operand == PlayReverseOperand || Operand == PlayReverseAlternativeOperand)
        return -1.0f;
    if (Operand == PlayForwardPauseOperand || Operand == PlayReversePauseOperand ||
        Operand == PlayNextFrameOperand || Operand == PlayPreviousFrameOperand)
        return 0.0f;
    if (Operand > PlayForwardOperand && Operand <= PlayFastestForwardOperand)
        return 2.0f;
    if (Operand >= PlaySlowestForwardOperand && Operand < PlayForwardOperand)
        return 0.5f;
    if (Operand > PlayReverseOperand && Operand <= PlayFastestReverseOperand)
        return -2.0f;
    if (Operand >= PlaySlowestReverseOperand && Operand < PlayReverseOperand)
        return -0.5f;
    return 1.0f;
}

static TransportPosition DescribeTransportState(UInt8 Opcode, UInt8 Operand)
{
    if (Opcode == LoadMediumOpcode)
        return {Playback_Mode_NotPlaying, 0.0f, "no cassette"};
    if (Opcode == RecordOpcode)
        return {Playback_Mode_Playing, 1.0f, "recording"};
    if (Opcode == PlayOpcode)
    {
        float Speed = ConvertPlayOperandToSpeed(Operand);
        if (Speed == 0.0f)
            return {Playback_Mode_Playing, 0.0f, "paused"};
        if (Speed == 1.0f)
            return {Playback_Mode_Playing, 1.0f, "playing"};
        return {Playback_Mode_Playing, Speed, Speed > 0 ? "fast-forwarding" : "rewinding"};
    }
    if (Opcode == WindOpcode && Operand == WindRewindOperand)
        return {Playback_Mode_NotPlaying, -2.0f, "rewinding"};
    if (Opcode == WindOpcode && Operand == WindFastForwardOperand)
        return {Playback_Mode_NotPlaying, 2.0f, "fast-forwarding"};
    return {Playback_Mode_NotPlaying, 0.0f, "stopped"};
}

static UInt8 ChoosePlayOperand(float Speed)
{
    if (Speed >= 2.0f)
        return PlayForwardOperand + SpeedStepCount;
    if (Speed > 1.0f)
        return PlayForwardOperand + SpeedStepCount - 1;
    if (Speed == 1.0f)
        return PlayForwardOperand;
    if (Speed > 0.0f)
        return PlayForwardOperand - SpeedStepCount + 1;
    if (Speed == 0.0f)
        return PlayForwardPauseOperand;
    if (Speed > -1.0f)
        return PlayReverseOperand + SpeedStepCount - 1;
    if (Speed == -1.0f)
        return PlayReverseOperand;
    if (Speed > -2.0f)
        return PlayReverseOperand - SpeedStepCount + 1;
    return PlayReverseOperand - SpeedStepCount;
}

static UInt8 ChooseWindOperand(float Speed)
{
    if (Speed > 0.0f)
        return WindFastForwardOperand;
    if (Speed < 0.0f)
        return WindRewindOperand;
    return WindStopOperand;
}

static NSArray* ListCaptureDevices()
{
    return [QTCaptureDevice inputDevicesWithMediaType:QTMediaTypeMuxed];
}

static IOFireWireAVCLibUnitInterface** OpenAvcUnit(NSString* UniqueID)
{
    UInt64 Guid = 0;
    [[NSScanner scannerWithString:UniqueID] scanHexLongLong:&Guid];
    if (!Guid)
        return NULL;

    CFMutableDictionaryRef MatchingDictionary = IOServiceMatching("IOFireWireAVCUnit");
    CFNumberRef GuidNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &Guid);
    CFDictionarySetValue(MatchingDictionary, CFSTR("GUID"), GuidNumber);
    CFRelease(GuidNumber);
    io_service_t Service = IOServiceGetMatchingService(kIOMasterPortDefault, MatchingDictionary);
    if (!Service)
        return NULL;

    IOFireWireAVCLibUnitInterface** AvcUnit = NULL;
    IOCFPlugInInterface** PlugInInterface = NULL;
    SInt32 Score = 0;
    if (IOCreatePlugInInterfaceForService(Service, kIOFireWireAVCLibUnitTypeID, kIOCFPlugInInterfaceID,
                                          &PlugInInterface, &Score) == kIOReturnSuccess && PlugInInterface)
    {
        (*PlugInInterface)->QueryInterface(PlugInInterface, CFUUIDGetUUIDBytes(kIOFireWireAVCLibUnitInterfaceID),
                                           (LPVOID*)&AvcUnit);
        (*PlugInInterface)->Release(PlugInInterface);
    }
    IOObjectRelease(Service);
    return AvcUnit;
}

// QTKit delivers the DV frames with silenced audio blocks and the audio separately as 16-bit PCM,
// so the audio is packed back into each frame (IEC 61834 12-bit layout, as read by FFmpeg's DV decoder)
static const size_t NtscDvFrameSize = 120000;
static const int DifBlockSize = 80;
static const int DifBlocksPerSequence = 150;
static const int NtscSequenceCount = 10;
static const int SequencesPerAudioChannelPair = 5;
static const int AudioBlocksPerSequence = 9;
static const int FirstAudioBlockInSequence = 6;
static const int DifBlocksBetweenAudioBlocks = 16;
static const int AudioPackOffset = 3;
static const int AudioDataOffset = 8;
static const int TwelveBitSamplePairsPerBlock = 24;
static const int InterleavedAudioSampleStride525 = 90;
static const int QtkitAudioChannelCount = 4;
static const UInt8 AudioSourcePackId = 0x50;
static const UInt8 TwelveBitQuantization = 1;
static const uint16_t TwelveBitErrorCode = 0x800;
static const double MaximumSecondsBetweenMatchingVideoAndAudio = 0.017;
static const double SecondsToWaitForMatchingAudio = 0.5;
static const int AudioShuffle525[SequencesPerAudioChannelPair][AudioBlocksPerSequence] = {
    { 0, 30, 60, 20, 50, 80, 10, 40, 70 },
    { 6, 36, 66, 26, 56, 86, 16, 46, 76 },
    { 12, 42, 72, 2, 32, 62, 22, 52, 82 },
    { 18, 48, 78, 8, 38, 68, 28, 58, 88 },
    { 24, 54, 84, 14, 44, 74, 4, 34, 64 },
};

static int ExpandTwelveBitSample(uint16_t Sample)
{
    uint16_t Extended = Sample < 0x800 ? Sample : Sample | 0xF000;
    uint16_t Shift = (Extended & 0xF00) >> 8;
    uint16_t Result;
    if (Shift < 0x2 || Shift > 0xD)
        Result = Extended;
    else if (Shift < 0x8)
    {
        Shift--;
        Result = (Extended - (256 * Shift)) << Shift;
    }
    else
    {
        Shift = 0xE - Shift;
        Result = ((Extended + ((256 * Shift) + 1)) << Shift) - 1;
    }
    return (int16_t)Result;
}

static vector<uint16_t> BuildTwelveBitCodeTable()
{
    vector<pair<int, uint16_t> > Levels;
    for (uint16_t Code = 0; Code < 0x1000; Code++)
        if (Code != TwelveBitErrorCode)
            Levels.push_back(make_pair(ExpandTwelveBitSample(Code), Code));
    sort(Levels.begin(), Levels.end());
    vector<uint16_t> CodeBySample(0x10000);
    size_t LevelIndex = 0;
    for (int Sample = -32768; Sample <= 32767; Sample++)
    {
        while (LevelIndex + 1 < Levels.size() && abs(Levels[LevelIndex + 1].first - Sample) <= abs(Levels[LevelIndex].first - Sample))
            LevelIndex++;
        CodeBySample[Sample + 32768] = Levels[LevelIndex].second;
    }
    return CodeBySample;
}

static uint16_t CompressToTwelveBitCode(int16_t Sample)
{
    static const vector<uint16_t> CodeBySample = BuildTwelveBitCodeTable();
    return CodeBySample[Sample + 32768];
}

static uint8_t* FindAudioBlock(uint8_t* Frame, int Sequence, int AudioBlock)
{
    return Frame + (Sequence * DifBlocksPerSequence + FirstAudioBlockInSequence + AudioBlock * DifBlocksBetweenAudioBlocks) * DifBlockSize;
}

static bool HasTwelveBitAudio(uint8_t* Frame)
{
    for (int Sequence = 0; Sequence < NtscSequenceCount; Sequence++)
        for (int AudioBlock = 0; AudioBlock < AudioBlocksPerSequence; AudioBlock++)
        {
            uint8_t* Pack = FindAudioBlock(Frame, Sequence, AudioBlock) + AudioPackOffset;
            if (Pack[0] == AudioSourcePackId)
                return (Pack[4] & 0x07) == TwelveBitQuantization;
        }
    return false;
}

static void PackAudioIntoDvFrame(vector<uint8_t>& Frame, const vector<int16_t>& Samples)
{
    if (Frame.size() != NtscDvFrameSize || !HasTwelveBitAudio(&Frame[0]))
        return;
    size_t SampleFrameCount = Samples.size() / QtkitAudioChannelCount;
    for (int Sequence = 0; Sequence < NtscSequenceCount; Sequence++)
    {
        int ChannelPair = Sequence / SequencesPerAudioChannelPair;
        for (int AudioBlock = 0; AudioBlock < AudioBlocksPerSequence; AudioBlock++)
        {
            uint8_t* Data = FindAudioBlock(&Frame[0], Sequence, AudioBlock) + AudioDataOffset;
            for (int SamplePair = 0; SamplePair < TwelveBitSamplePairsPerBlock; SamplePair++)
            {
                size_t SampleFrame = (AudioShuffle525[Sequence % SequencesPerAudioChannelPair][AudioBlock] + SamplePair * InterleavedAudioSampleStride525) / 2;
                if (SampleFrame >= SampleFrameCount)
                    continue;
                uint16_t Left = CompressToTwelveBitCode(Samples[SampleFrame * QtkitAudioChannelCount + ChannelPair * 2]);
                uint16_t Right = CompressToTwelveBitCode(Samples[SampleFrame * QtkitAudioChannelCount + ChannelPair * 2 + 1]);
                Data[SamplePair * 3] = Left >> 4;
                Data[SamplePair * 3 + 1] = Right >> 4;
                Data[SamplePair * 3 + 2] = ((Left & 0x0F) << 4) | (Right & 0x0F);
            }
        }
    }
}

struct PendingVideoFrame
{
    vector<uint8_t> Bytes;
    double Seconds;
    bool HasAudio;
};

struct PendingAudio
{
    vector<int16_t> Samples;
    double Seconds;
};

static double ConvertToSeconds(QTTime Time)
{
    return Time.timeScale ? (double)Time.timeValue / Time.timeScale : 0.0;
}

@interface QTKitFrameReceiver : NSObject
{
@public
    FileWrapper* FrameConsumer;
    volatile CFAbsoluteTime LastFrameArrival;
    deque<PendingVideoFrame>* PendingVideoFrames;
    deque<PendingAudio>* PendingAudioBuffers;
    size_t FramesPassedWithAudio;
    size_t FramesPassedWithoutAudio;
    size_t BuffersLogged;
}
- (void)passAllFrames;
@end

@implementation QTKitFrameReceiver
- (id)init
{
    self = [super init];
    if (self)
    {
        PendingVideoFrames = new deque<PendingVideoFrame>();
        PendingAudioBuffers = new deque<PendingAudio>();
    }
    return self;
}

- (void)dealloc
{
    delete PendingVideoFrames;
    delete PendingAudioBuffers;
    [super dealloc];
}

- (void)passFrontFrame
{
    PendingVideoFrame& Frame = PendingVideoFrames->front();
    if (Frame.HasAudio)
        FramesPassedWithAudio++;
    else
        FramesPassedWithoutAudio++;
    if (FrameConsumer)
        FrameConsumer->Parse_Buffer(&Frame.Bytes[0], Frame.Bytes.size());
    PendingVideoFrames->pop_front();
}

- (void)packWaitingAudio
{
    for (deque<PendingAudio>::iterator Audio = PendingAudioBuffers->begin(); Audio != PendingAudioBuffers->end();)
    {
        deque<PendingVideoFrame>::iterator Frame = PendingVideoFrames->begin();
        while (Frame != PendingVideoFrames->end() && (Frame->HasAudio || fabs(Frame->Seconds - Audio->Seconds) > MaximumSecondsBetweenMatchingVideoAndAudio))
            ++Frame;
        if (Frame == PendingVideoFrames->end())
        {
            ++Audio;
            continue;
        }
        PackAudioIntoDvFrame(Frame->Bytes, Audio->Samples);
        Frame->HasAudio = true;
        Audio = PendingAudioBuffers->erase(Audio);
    }
}

- (void)passFramesReadyBefore:(double)OldestSecondsToKeepWaiting
{
    while (!PendingVideoFrames->empty() && (PendingVideoFrames->front().HasAudio || PendingVideoFrames->front().Seconds < OldestSecondsToKeepWaiting))
        [self passFrontFrame];
    while (!PendingAudioBuffers->empty() && PendingAudioBuffers->front().Seconds < OldestSecondsToKeepWaiting)
        PendingAudioBuffers->pop_front();
}

- (void)passAllFrames
{
    @synchronized(self) {
        [self packWaitingAudio];
        size_t UnusedAudioBuffers = PendingAudioBuffers->size();
        while (!PendingVideoFrames->empty())
            [self passFrontFrame];
        PendingAudioBuffers->clear();
        if (getenv("DVRESCUE_QTKIT_AUDIO_LOG"))
            NSLog(@"QTKit audio: %lu frames with audio, %lu without, %lu audio buffers unused",
                  (unsigned long)FramesPassedWithAudio, (unsigned long)FramesPassedWithoutAudio, (unsigned long)UnusedAudioBuffers);
    }
}

- (void)captureOutput:(QTCaptureFileOutput*)CaptureOutput
  didOutputSampleBuffer:(QTSampleBuffer*)SampleBuffer
         fromConnection:(QTCaptureConnection*)Connection
{
    NSUInteger Length = [SampleBuffer lengthForAllSamples];
    if (!Length)
        return;
    double Seconds = ConvertToSeconds([SampleBuffer presentationTime]);
    NSString* MediaType = [Connection mediaType];
    @synchronized(self) {
        BuffersLogged++;
        if (getenv("DVRESCUE_QTKIT_AUDIO_LOG") && BuffersLogged % 31 == 0)
        {
            long SampleMagnitude = 0;
            if ([MediaType isEqualToString:QTMediaTypeSound])
                for (NSUInteger Index = 0; Index < Length / sizeof(int16_t); Index++)
                    SampleMagnitude += abs(((const int16_t*)[SampleBuffer bytesForAllSamples])[Index]);
            NSLog(@"QTKit buffer %@ at %.4f s, %lu bytes, sample magnitude %ld, format %@", MediaType, Seconds, (unsigned long)Length,
                  SampleMagnitude, [[SampleBuffer formatDescription] localizedFormatSummary]);
        }
        if ([MediaType isEqualToString:QTMediaTypeVideo])
        {
            LastFrameArrival = CFAbsoluteTimeGetCurrent();
            const uint8_t* Bytes = (const uint8_t*)[SampleBuffer bytesForAllSamples];
            PendingVideoFrame Frame = { vector<uint8_t>(Bytes, Bytes + Length), Seconds, false };
            PendingVideoFrames->push_back(Frame);
        }
        else if ([MediaType isEqualToString:QTMediaTypeSound])
        {
            const int16_t* Samples = (const int16_t*)[SampleBuffer bytesForAllSamples];
            PendingAudio Audio = { vector<int16_t>(Samples, Samples + Length / sizeof(int16_t)), Seconds };
            PendingAudioBuffers->push_back(Audio);
        }
        else
            return;
        [self packWaitingAudio];
        [self passFramesReadyBefore:Seconds - SecondsToWaitForMatchingAudio];
    }
}
@end

@interface QTKitCtl : NSObject
{
@public
    QTCaptureDevice* Device;
    QTCaptureSession* Session;
    QTCaptureMovieFileOutput* Output;
    QTKitFrameReceiver* Receiver;
    IOFireWireAVCLibUnitInterface** AvcUnit;
    ControllerBaseWrapper* ExternalController;
}
- (id)initWithDevice:(QTCaptureDevice*)CaptureDevice controller:(ControllerBaseWrapper*)Controller;
- (TransportPosition)readTransportPosition;
- (void)sendTransportCommand:(UInt8)Opcode operand:(UInt8)Operand;
@end

@implementation QTKitCtl
- (id)initWithDevice:(QTCaptureDevice*)CaptureDevice controller:(ControllerBaseWrapper*)Controller
{
    self = [super init];
    if (!self)
        return nil;
    Device = [CaptureDevice retain];
    ExternalController = Controller;
    AvcUnit = OpenAvcUnit([Device uniqueID]);
    if (!AvcUnit && !ExternalController)
        NSLog(@"Warning: could not open the AV/C unit, falling back to QTKit transport controls");
    return self;
}

- (void)dealloc
{
    if ([Session isRunning])
        [Session stopRunning];
    [Output setDelegate:nil];
    [Session release];
    [Output release];
    [Receiver release];
    if ([Device isOpen])
        [Device close];
    [Device release];
    if (AvcUnit)
        (*AvcUnit)->Release(AvcUnit);
    [super dealloc];
}

- (TransportPosition)readTransportPositionFromQTKit
{
    NSDictionary* Controls = [Device attributeForKey:QTCaptureDeviceAVCTransportControlsAttribute];
    int Mode = [[Controls objectForKey:QTCaptureDeviceAVCTransportControlsPlaybackModeKey] intValue];
    int Speed = [[Controls objectForKey:QTCaptureDeviceAVCTransportControlsSpeedKey] intValue];
    if (Mode == QTCaptureDeviceAVCTransportControlsPlayingMode)
        return {Playback_Mode_Playing, Speed / 10000.0f, Speed == QTCaptureDeviceAVCTransportControlsNormalForwardSpeed ? "playing" : "unknown"};
    if (Speed > 0)
        return {Playback_Mode_NotPlaying, 2.0f, "fast-forwarding"};
    if (Speed < 0)
        return {Playback_Mode_NotPlaying, -2.0f, "rewinding"};
    return {Playback_Mode_NotPlaying, 0.0f, "stopped"};
}

- (TransportPosition)readTransportPosition
{
    if (!AvcUnit)
        return [self readTransportPositionFromQTKit];
    UInt8 Command[4] = {AvcStatusCommand, TapeRecorderSubunit, TransportStateOpcode, 0x7F};
    UInt8 Response[8] = {0};
    UInt32 ResponseLength = sizeof(Response);
    IOReturn Result;
    @synchronized(self) {
        Result = (*AvcUnit)->AVCCommand(AvcUnit, Command, sizeof(Command), Response, &ResponseLength);
    }
    if (Result != kIOReturnSuccess || ResponseLength < 4 ||
        (Response[0] != AvcStableResponse && Response[0] != AvcInTransitionResponse))
        return {Playback_Mode_NotPlaying, 0.0f, "unknown"};
    return DescribeTransportState(Response[2], Response[3]);
}

- (void)sendTransportCommand:(UInt8)Opcode operand:(UInt8)Operand
{
    UInt8 Command[4] = {AvcControlCommand, TapeRecorderSubunit, Opcode, Operand};
    UInt8 Response[8] = {0};
    UInt32 ResponseLength = sizeof(Response);
    @synchronized(self) {
        if ((*AvcUnit)->AVCCommand(AvcUnit, Command, sizeof(Command), Response, &ResponseLength) != kIOReturnSuccess)
            NSLog(@"Error: failed to send AV/C command %02x %02x", Opcode, Operand);
    }
}

- (void)sendTransportCommandThroughQTKit:(playback_mode)Mode speed:(float)Speed
{
    int QTKitSpeed = (int)(Speed * QTCaptureDeviceAVCTransportControlsNormalForwardSpeed);
    NSDictionary* Controls = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithInt:Mode == Playback_Mode_Playing ? QTCaptureDeviceAVCTransportControlsPlayingMode
                                                              : QTCaptureDeviceAVCTransportControlsNotPlayingMode],
        QTCaptureDeviceAVCTransportControlsPlaybackModeKey,
        [NSNumber numberWithInt:QTKitSpeed], QTCaptureDeviceAVCTransportControlsSpeedKey, nil];
    [Device setAttribute:Controls forKey:QTCaptureDeviceAVCTransportControlsAttribute];
}
@end

const string QTKitCtlWrapper::Interface = "DV";

static QTCaptureDevice* FindCaptureDeviceAt(size_t DeviceIndex)
{
    NSArray* Devices = ListCaptureDevices();
    return DeviceIndex < [Devices count] ? (QTCaptureDevice*)[Devices objectAtIndex:DeviceIndex] : nil;
}

static QTKitCtl* CreateCtl(QTCaptureDevice* CaptureDevice, ControllerBaseWrapper* ExtCtl)
{
    NSError* Error = nil;
    if (!CaptureDevice || ![CaptureDevice open:&Error])
        throw runtime_error("unable to open the capture device");
    return [[QTKitCtl alloc] initWithDevice:CaptureDevice controller:ExtCtl];
}

QTKitCtlWrapper::QTKitCtlWrapper(size_t DeviceIndex, ControllerBaseWrapper* ExtCtl) : ExtCtl(ExtCtl)
{
    @autoreleasepool {
        Ctl = CreateCtl(FindCaptureDeviceAt(DeviceIndex), ExtCtl);
    }
}

QTKitCtlWrapper::QTKitCtlWrapper(string DeviceID, ControllerBaseWrapper* ExtCtl) : ExtCtl(ExtCtl)
{
    @autoreleasepool {
        Ctl = CreateCtl(FindCaptureDeviceAt(GetDeviceIndex(DeviceID)), ExtCtl);
    }
}

QTKitCtlWrapper::~QTKitCtlWrapper()
{
    @autoreleasepool {
        [(QTKitCtl*)Ctl release];
    }
}

size_t QTKitCtlWrapper::GetDeviceCount()
{
    @autoreleasepool {
        return (size_t)[ListCaptureDevices() count];
    }
}

string QTKitCtlWrapper::GetDeviceName(size_t DeviceIndex)
{
    @autoreleasepool {
        QTCaptureDevice* CaptureDevice = FindCaptureDeviceAt(DeviceIndex);
        return CaptureDevice ? string([[CaptureDevice localizedDisplayName] UTF8String]) : string();
    }
}

string QTKitCtlWrapper::GetDeviceID(size_t DeviceIndex)
{
    @autoreleasepool {
        QTCaptureDevice* CaptureDevice = FindCaptureDeviceAt(DeviceIndex);
        return CaptureDevice ? string([[CaptureDevice uniqueID] UTF8String]) : string();
    }
}

size_t QTKitCtlWrapper::GetDeviceIndex(const string& DeviceID)
{
    @autoreleasepool {
        NSString* WantedID = [NSString stringWithUTF8String:DeviceID.c_str()];
        for (size_t DeviceIndex = 0; FindCaptureDeviceAt(DeviceIndex); DeviceIndex++)
            if ([[FindCaptureDeviceAt(DeviceIndex) uniqueID] caseInsensitiveCompare:WantedID] == NSOrderedSame)
                return DeviceIndex;
        return (size_t)-1;
    }
}

string QTKitCtlWrapper::GetStatus()
{
    if (ExtCtl)
        return ExtCtl->GetStatus();
    @autoreleasepool {
        return [(QTKitCtl*)Ctl readTransportPosition].Description;
    }
}

float QTKitCtlWrapper::GetSpeed()
{
    if (ExtCtl)
        return ExtCtl->GetSpeed();
    @autoreleasepool {
        return [(QTKitCtl*)Ctl readTransportPosition].Speed;
    }
}

playback_mode QTKitCtlWrapper::GetMode()
{
    if (ExtCtl)
        return ExtCtl->GetMode();
    @autoreleasepool {
        return [(QTKitCtl*)Ctl readTransportPosition].Mode;
    }
}

void QTKitCtlWrapper::CreateCaptureSession(FileWrapper* Wrapper)
{
    @autoreleasepool {
        QTKitCtl* Controller = (QTKitCtl*)Ctl;
        if (Controller->Session)
        {
            Controller->Receiver->FrameConsumer = Wrapper;
            return;
        }
        NSError* Error = nil;
        Controller->Session = [[QTCaptureSession alloc] init];
        QTCaptureDeviceInput* Input = [[[QTCaptureDeviceInput alloc] initWithDevice:Controller->Device] autorelease];
        if (![Controller->Session addInput:Input error:&Error])
        {
            NSLog(@"Error adding the capture input: %@", Error);
            return;
        }
        Controller->Receiver = [[QTKitFrameReceiver alloc] init];
        Controller->Receiver->FrameConsumer = Wrapper;
        Controller->Output = [[QTCaptureMovieFileOutput alloc] init];
        [Controller->Output setDelegate:Controller->Receiver];
        if (![Controller->Session addOutput:Controller->Output error:&Error])
            NSLog(@"Error adding the capture output: %@", Error);
    }
}

void QTKitCtlWrapper::StartCaptureSession()
{
    @autoreleasepool {
        [((QTKitCtl*)Ctl)->Session startRunning];
    }
}

void QTKitCtlWrapper::StopCaptureSession()
{
    @autoreleasepool {
        QTKitCtl* Controller = (QTKitCtl*)Ctl;
        [Controller->Session stopRunning];
        [Controller->Receiver passAllFrames];
    }
}

void QTKitCtlWrapper::SetPlaybackMode(playback_mode Mode, float Speed)
{
    if (ExtCtl)
    {
        ExtCtl->SetPlaybackMode(Mode, Speed);
        return;
    }
    @autoreleasepool {
        QTKitCtl* Controller = (QTKitCtl*)Ctl;
        if (!Controller->AvcUnit)
            [Controller sendTransportCommandThroughQTKit:Mode speed:Speed];
        else if (Mode == Playback_Mode_Playing)
            [Controller sendTransportCommand:PlayOpcode operand:ChoosePlayOperand(Speed)];
        else
            [Controller sendTransportCommand:WindOpcode operand:ChooseWindOperand(Speed)];
    }
}

void QTKitCtlWrapper::RunMainThreadWork(double Seconds)
{
    @autoreleasepool {
        if ([NSThread isMainThread])
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:Seconds]];
        else
            [NSThread sleepForTimeInterval:Seconds];
    }
}

bool QTKitCtlWrapper::WaitForSessionEnd(uint64_t Timeout)
{
    CFAbsoluteTime WaitStart = CFAbsoluteTimeGetCurrent();
    while (GetSpeed() == 0.0f && CFAbsoluteTimeGetCurrent() - WaitStart < SecondsToWaitForPlaybackToBegin)
        RunMainThreadWork(SecondsBetweenTransportPolls);

    QTKitFrameReceiver* Receiver = ((QTKitCtl*)Ctl)->Receiver;
    if (Receiver)
        Receiver->LastFrameArrival = CFAbsoluteTimeGetCurrent();

    while (GetSpeed() != 0.0f)
    {
        bool InputTimedOut = Timeout && Receiver && CFAbsoluteTimeGetCurrent() - Receiver->LastFrameArrival > Timeout;
        if (InputTimedOut)
        {
            SetPlaybackMode(Playback_Mode_NotPlaying, 0.0f);
            return true;
        }
        RunMainThreadWork(SecondsBetweenTransportPolls);
    }
    return false;
}
