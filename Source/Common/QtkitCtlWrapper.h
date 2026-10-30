/*  Copyright (c) MIPoPS. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-3-Clause license that can
 *  be found in the LICENSE.txt file in the root of the source tree.
 */

//---------------------------------------------------------------------------
#pragma once

#include <cstddef>
#include <string>

#include "Common/ProcessFileWrapper.h"

//***************************************************************************
// Class QTKitCtlWrapper: FireWire DV capture for Mac OS X 10.5/10.6 (QTKit + AV/C)
//***************************************************************************

class QTKitCtlWrapper : public BaseWrapper {
public:
    // Constructor/Destructor
    QTKitCtlWrapper(std::size_t DeviceIndex, ControllerBaseWrapper* ExtCtl = nullptr);
    QTKitCtlWrapper(std::string DeviceID, ControllerBaseWrapper* ExtCtl = nullptr);
    ~QTKitCtlWrapper();

    // Functions
    static std::size_t GetDeviceCount();
    static std::string GetDeviceName(std::size_t DeviceIndex);
    static std::string GetDeviceID(std::size_t DeviceIndex);
    static std::size_t GetDeviceIndex(const std::string& DeviceID);
    static void RunMainThreadWork(double Seconds);
    std::string GetStatus();
    float GetSpeed();
    playback_mode GetMode();
    void CreateCaptureSession(FileWrapper* Wrapper);
    void StartCaptureSession();
    void StopCaptureSession();
    void SetPlaybackMode(playback_mode Mode, float Speed);
    bool WaitForSessionEnd(uint64_t Timeout);

    // Attributes
    static const std::string Interface;

private:
    void* Ctl;
    ControllerBaseWrapper* ExtCtl;
};
