cmake_minimum_required(VERSION 3.21)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "Minimum macOS version")
project(foo_windows_properties VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OBJC_VISIBILITY_PRESET hidden)
set(CMAKE_OBJCXX_VISIBILITY_PRESET hidden)

option(WPE_BUILD_COMPONENT "Build Windows Properties, foo_windows_properties.component (needs the foobar2000 SDK)" ON)
option(WPE_BUILD_TESTS "Build the unit tests" ON)

set(WPE_WARNINGS -Wall -Wextra)

# Pure C++ model: no SDK, no Cocoa.
add_library(wpe_model STATIC src/wpe_model.cpp src/wpe_art.cpp src/wpe_rg.cpp src/wpe_details.cpp)
target_include_directories(wpe_model PUBLIC "${CMAKE_SOURCE_DIR}/src")
target_compile_options(wpe_model PRIVATE ${WPE_WARNINGS})

if(WPE_BUILD_TESTS)
  add_executable(wpe_tests tests/test_model.cpp tests/test_art.cpp tests/test_rg.cpp tests/test_details.cpp)
  target_link_libraries(wpe_tests PRIVATE wpe_model)
  target_compile_options(wpe_tests PRIVATE ${WPE_WARNINGS})
endif()

if(NOT WPE_BUILD_COMPONENT)
  return()
endif()

if(NOT APPLE)
  message(FATAL_ERROR "Windows Properties (foo_windows_properties) is a foobar2000 for Mac component; configure with -DWPE_BUILD_COMPONENT=OFF to build only the tests")
endif()

# The foobar2000 SDK is not part of this repository: scripts/fetch-sdk.sh downloads it into
# third_party/foobar2000-sdk (the default), or pass -DSDK_ROOT=/path/containing/foobar2000+pfc.
set(SDK_ROOT "${CMAKE_SOURCE_DIR}/third_party/foobar2000-sdk" CACHE PATH "Directory containing foobar2000/ and pfc/ from the foobar2000 SDK")
get_filename_component(SDK "${SDK_ROOT}" ABSOLUTE)
foreach(_req pfc foobar2000/SDK foobar2000/foobar2000_component_client foobar2000/shared foobar2000/helpers-mac)
  if(NOT EXISTS "${SDK}/${_req}")
    message(FATAL_ERROR "foobar2000 SDK not found: ${SDK}/${_req} is missing (run scripts/fetch-sdk.sh, or pass -DSDK_ROOT=/path/containing/foobar2000+pfc)")
  endif()
endforeach()

enable_language(OBJC OBJCXX)
set(CMAKE_OBJCXX_STANDARD 20)
add_compile_definitions(NDEBUG)

set(PFC_NAMES SmartStrStr audio_math audio_sample base64 bigmem bit_array bsearch charDownConvert
  cpuid crashWithMessage filehandle filetimetools guid nix-objects other pathUtils printf selftest
  sort splitString2 string-compare string-conv-lite string-lite string_base string_conv
  synchro_nix threads timers unicode-normalize utf8 wildcard)
set(PFC_SRC "${SDK}/pfc/obj-c.mm")
foreach(n ${PFC_NAMES})
  list(APPEND PFC_SRC "${SDK}/pfc/${n}.cpp")
endforeach()

set(SDK_NAMES abort_callback advconfig album_art app_close_blocker audio_chunk
  audio_chunk_channel_config cfg_var chapterizer commonObjects completion_notify configStore
  config_io_callback config_object console dsp dsp_manager file_cached_impl file_info
  file_info_const_impl file_info_impl file_info_merge file_operation_callback filesystem
  filesystem_helper foosort fsItem guids hasher_md5 image input input_file_type link_resolver
  main_thread_callback mainmenu mem_block_container menu_helpers menu_item menu_manager metadb
  metadb_handle metadb_handle_list output packet_decoder playable_location playback_control
  playlist playlist_loader popup_message preferences_page replaygain replaygain_info service
  tag_processor tag_processor_id3v2 threaded_process titleformat track_property ui ui_element
  utility)
set(SDK_SRC "${SDK}/foobar2000/SDK/apple-tools.mm" "${SDK}/foobar2000/SDK/commonObjects-Apple.mm"
  "${SDK}/foobar2000/foobar2000_component_client/component_client.cpp"
  "${SDK}/foobar2000/shared/audio_math.cpp" "${SDK}/foobar2000/shared/shared-apple.mm"
  "${SDK}/foobar2000/shared/shared-nix.cpp" "${SDK}/foobar2000/shared/utf8.cpp")
foreach(n ${SDK_NAMES})
  list(APPEND SDK_SRC "${SDK}/foobar2000/SDK/${n}.cpp")
endforeach()

add_library(pfc STATIC ${PFC_SRC})
target_include_directories(pfc SYSTEM PUBLIC "${SDK}")
add_library(fb2ksdk STATIC ${SDK_SRC})
target_include_directories(fb2ksdk SYSTEM PUBLIC "${SDK}" "${SDK}/foobar2000")
target_link_libraries(fb2ksdk PUBLIC pfc)
foreach(t pfc fb2ksdk)
  target_compile_options(${t} PRIVATE -w $<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-arc>)
endforeach()

# SDK bridge: SDK types, no Cocoa (shared by the component and the SDK test).
add_library(wpe_sdk STATIC src/wpe_sdk.cpp)
target_link_libraries(wpe_sdk PUBLIC wpe_model fb2ksdk)
target_compile_options(wpe_sdk PRIVATE ${WPE_WARNINGS})

add_library(foo_windows_properties MODULE src/component.cpp src/wpe_backend_fb2k.cpp src/wpe_window.mm src/wpe_value_sheet.mm src/wpe_chrome.mm)
set_target_properties(foo_windows_properties PROPERTIES
  BUNDLE TRUE
  BUNDLE_EXTENSION component
  MACOSX_BUNDLE_BUNDLE_NAME foo_windows_properties
  MACOSX_BUNDLE_GUI_IDENTIFIER io.github.metal2050.foo_windows_properties
  MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/cmake/mac/Info.plist.in")
target_compile_definitions(foo_windows_properties PRIVATE WPE_VERSION="${PROJECT_VERSION}")
target_compile_options(foo_windows_properties PRIVATE ${WPE_WARNINGS} $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_link_libraries(foo_windows_properties PRIVATE wpe_sdk wpe_model fb2ksdk pfc "-framework Cocoa" "-framework ImageIO"
  "-framework Quartz" "-framework UniformTypeIdentifiers")

if(WPE_BUILD_TESTS)
  add_executable(wpe_sdk_tests tests/test_sdk_bridge.cpp)
  target_link_libraries(wpe_sdk_tests PRIVATE wpe_sdk wpe_model fb2ksdk pfc "-framework Cocoa")
  target_compile_options(wpe_sdk_tests PRIVATE ${WPE_WARNINGS})

  # The real window against an in-memory backend (no SDK libraries; helpers-mac header only), linked
  # twice. wpe_ui_tests embeds tests/host-design-Info.plist (UIDesignRequiresCompatibility, as in
  # foobar2000.app's Info.plist), so AppKit lays out and draws the window in the classic design it gets in
  # the host; wpe_ui_tests_macos26 has no Info.plist and runs the macOS 26 design.
  add_library(wpe_ui_objs OBJECT tests/test_ui.mm src/wpe_window.mm src/wpe_value_sheet.mm src/wpe_chrome.mm)
  target_include_directories(wpe_ui_objs SYSTEM PRIVATE "${SDK}")
  target_link_libraries(wpe_ui_objs PRIVATE wpe_model)
  target_compile_options(wpe_ui_objs PRIVATE ${WPE_WARNINGS} $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
  set(WPE_HOST_DESIGN_PLIST "${CMAKE_SOURCE_DIR}/tests/host-design-Info.plist")
  foreach(t wpe_ui_tests wpe_ui_tests_macos26)
    add_executable(${t} $<TARGET_OBJECTS:wpe_ui_objs>)
    target_link_libraries(${t} PRIVATE wpe_model "-framework Cocoa" "-framework ApplicationServices" "-framework ImageIO"
      "-framework Quartz" "-framework UniformTypeIdentifiers")
  endforeach()
  target_link_options(wpe_ui_tests PRIVATE "LINKER:-sectcreate,__TEXT,__info_plist,${WPE_HOST_DESIGN_PLIST}")
  set_property(TARGET wpe_ui_tests APPEND PROPERTY LINK_DEPENDS "${WPE_HOST_DESIGN_PLIST}")
endif()
