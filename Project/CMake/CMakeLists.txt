project(dvrescue)

cmake_minimum_required(VERSION 2.8.11)

find_package(ZenLib REQUIRED)
find_package(MediaInfoLib REQUIRED)

if(APPLE AND CMAKE_OSX_DEPLOYMENT_TARGET AND CMAKE_OSX_DEPLOYMENT_TARGET VERSION_LESS 10.7)
  option(BUILD_QTKITCTL "Build QTKit FireWire capture (Mac OS X 10.5/10.6)" ON)
  set(BUILD_AVFCTL OFF)
elseif(APPLE)
  option(BUILD_AVFCTL "Build avfctl tool (macOS only)" ON)
  set(BUILD_QTKITCTL OFF)
else()
  set(BUILD_AVFCTL OFF)
  set(BUILD_QTKITCTL OFF)
endif()

set(dvrescue_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR}/../..)
set(dvrescue_SOURCES_PATH ${dvrescue_ROOT_PATH}/Source)

set(dvrescue_SRCS
  ${dvrescue_SOURCES_PATH}/CLI/CLI_Help.cpp
  ${dvrescue_SOURCES_PATH}/CLI/CLI_Main.cpp
  ${dvrescue_SOURCES_PATH}/CLI/CommandLine_Parser.cpp
  ${dvrescue_SOURCES_PATH}/CLI/DVRescue.rc
  ${dvrescue_SOURCES_PATH}/Common/Core.cpp
  ${dvrescue_SOURCES_PATH}/Common/Merge.cpp
  ${dvrescue_SOURCES_PATH}/Common/Output.cpp
  ${dvrescue_SOURCES_PATH}/Common/Output_Captions_Decode.cpp
  ${dvrescue_SOURCES_PATH}/Common/Output_Captions_Scc.cpp
  ${dvrescue_SOURCES_PATH}/Common/Output_Webvtt.cpp
  ${dvrescue_SOURCES_PATH}/Common/Output_Xml.cpp
  ${dvrescue_SOURCES_PATH}/Common/ProcessFile.cpp
  ${dvrescue_SOURCES_PATH}/Common/ProcessFileWrapper.cpp
  ${dvrescue_SOURCES_PATH}/Common/SimulatorWrapper.cpp
  ${dvrescue_SOURCES_PATH}/ThirdParty/ccdecoder/ccdecoder_internal.c
  ${dvrescue_SOURCES_PATH}/ThirdParty/ccdecoder/ccdecoder_line21.c
  ${dvrescue_SOURCES_PATH}/ThirdParty/ccdecoder/ccdecoder_line21field.c
  ${dvrescue_SOURCES_PATH}/ThirdParty/ccdecoder/ccdecoder_onscreen.c
  ${dvrescue_SOURCES_PATH}/ThirdParty/ccdecoder/ccdecoder_subrip.c
  ${dvrescue_SOURCES_PATH}/ThirdParty/TimeCode/TimeCode.cpp
)

option(BUILD_SIMULATOR "Enable capture simulation for testing purposes" ON)
if(BUILD_SIMULATOR)
  list(APPEND dvrescue_SRCS
    ${dvrescue_SOURCES_PATH}/Common/Output_Mkv.cpp
    ${dvrescue_SOURCES_PATH}/Common/SignalStats.cpp
  )
endif()

if(BUILD_QTKITCTL)
  set(dvrescue_QTKITCTL_SOURCE ${dvrescue_SOURCES_PATH}/Common/QtkitCtlWrapper.mm)
  set_source_files_properties(${dvrescue_QTKITCTL_SOURCE} PROPERTIES LANGUAGE CXX COMPILE_FLAGS "-x objective-c++")
  list(APPEND dvrescue_SRCS ${dvrescue_QTKITCTL_SOURCE})
endif()

set(dvrescue_TOOLS
  ${dvrescue_ROOT_PATH}/tools/dvloupe
  ${dvrescue_ROOT_PATH}/tools/dvmap
  ${dvrescue_ROOT_PATH}/tools/dvpackager
  ${dvrescue_ROOT_PATH}/tools/dvplay
  ${dvrescue_ROOT_PATH}/tools/dvsampler
)

if(BUILD_AVFCTL)
  add_custom_command(OUTPUT ${dvrescue_ROOT_PATH}/tools/avfctl/avfctl
                     COMMAND make
                     WORKING_DIRECTORY ${dvrescue_ROOT_PATH}/tools/avfctl
  )
  add_custom_target(avfctl ALL DEPENDS ${dvrescue_ROOT_PATH}/tools/avfctl/avfctl)
  list(APPEND dvrescue_TOOLS ${dvrescue_ROOT_PATH}/tools/avfctl/avfctl)
endif()

add_executable(dvrescue
  ${dvrescue_SRCS}
)
target_include_directories(dvrescue
  PRIVATE ${dvrescue_SOURCES_PATH}
  PRIVATE ${dvrescue_SOURCES_PATH}/ThirdParty/ccdecoder
  PRIVATE ${dvrescue_SOURCES_PATH}/ThirdParty/TimeCode
)
target_link_libraries(dvrescue
  ${ZenLib_LIBRARY}
  ${MediaInfoLib_LIBRARY}
)
set_target_properties(dvrescue PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)
if(BUILD_SIMULATOR)
  target_compile_definitions(dvrescue PRIVATE ENABLE_SIMULATOR)
endif()
if(BUILD_QTKITCTL)
  target_compile_definitions(dvrescue PRIVATE ENABLE_CAPTURE ENABLE_QTKITCTL)
  target_link_libraries(dvrescue "-framework QTKit" "-framework Foundation" "-framework IOKit" "-framework CoreFoundation")
endif()

install(TARGETS dvrescue DESTINATION bin)
if(UNIX)
  install(PROGRAMS ${dvrescue_TOOLS} DESTINATION bin)
endif()

if(NOT TARGET uninstall)
  configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/cmake_uninstall.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/cmake_uninstall.cmake"
    IMMEDIATE @ONLY
  )
  add_custom_target(uninstall
    "${CMAKE_COMMAND}" -P "${CMAKE_CURRENT_BINARY_DIR}/cmake_uninstall.cmake"
  )
endif()
