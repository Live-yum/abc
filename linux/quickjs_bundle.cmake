# flutter_js 0.8.7 installs this runtime into its plugin-local default bundle
# and exports flutter_qjs_bundled_libraries instead of the generated collector's
# flutter_js_bundled_libraries. Include the prebuilt runtime in the parent's
# real bundle list for Debug, Profile, and Release builds.
get_target_property(ABC_FLUTTER_JS_SOURCE_DIR flutter_js_plugin SOURCE_DIR)
set(ABC_QUICKJS_RUNTIME
  "${ABC_FLUTTER_JS_SOURCE_DIR}/shared/libquickjs_c_bridge_plugin.so")
if(NOT EXISTS "${ABC_QUICKJS_RUNTIME}")
  message(FATAL_ERROR "The pinned flutter_js Linux QuickJS runtime is missing: ${ABC_QUICKJS_RUNTIME}")
endif()
list(APPEND PLUGIN_BUNDLED_LIBRARIES "${ABC_QUICKJS_RUNTIME}")
list(REMOVE_DUPLICATES PLUGIN_BUNDLED_LIBRARIES)
