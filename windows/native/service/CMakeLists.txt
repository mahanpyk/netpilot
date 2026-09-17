add_executable(NetPilotService
  service_main.cpp
  service_runtime.cpp
  route_manager.cpp
  wfp_policy.cpp
  relay_engine.cpp
  diagnostics.cpp
  ../common/netpilot_protocol.cpp
)
apply_standard_settings(NetPilotService)
target_compile_definitions(NetPilotService PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(NetPilotService PRIVATE advapi32 fwpuclnt iphlpapi ole32 rpcrt4 shell32 ws2_32)
install(TARGETS NetPilotService RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
