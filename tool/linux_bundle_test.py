"""Exercise actual CMake install ordering without compiling Flutter or native code."""
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = "libquickjs_c_bridge_plugin.so"


class LinuxQuickJsBundleTests(unittest.TestCase):
    def make_project(self, directory, *, fixed=True, runtime=True):
        root = Path(directory)
        plugin = root / "plugin"
        (plugin / "shared").mkdir(parents=True)
        payload = b"test fixture for the pinned plugin's prebuilt runtime\n"
        if runtime:
            (plugin / "shared" / RUNTIME).write_bytes(payload)
        # Preserve the pinned plugin's local default install prefix and the
        # bundled-library variable the generated collector does not read.
        (plugin / "CMakeLists.txt").write_text(f'''
project(flutter_js LANGUAGES NONE)
add_library(flutter_js_plugin INTERFACE)
set(BUILD_BUNDLE_DIR "${{PROJECT_BINARY_DIR}}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${{BUILD_BUNDLE_DIR}}" CACHE PATH "..." FORCE)
endif()
set(flutter_qjs_bundled_libraries "unused-wrong-variable" PARENT_SCOPE)
install(FILES "${{CMAKE_CURRENT_SOURCE_DIR}}/shared/{RUNTIME}"
  DESTINATION "${{CMAKE_INSTALL_PREFIX}}/lib" COMPONENT Runtime)
''')
        helper = (
            f'include("{ROOT / "linux/quickjs_bundle.cmake"}")'
            if fixed else ""
        )
        (root / "CMakeLists.txt").write_text(f'''
cmake_minimum_required(VERSION 3.13)
project(quickjs_install_contract LANGUAGES NONE)
set(PLUGIN_BUNDLED_LIBRARIES)
add_subdirectory(plugin)
list(APPEND PLUGIN_BUNDLED_LIBRARIES ${{flutter_js_bundled_libraries}})
{helper}
set(BUILD_BUNDLE_DIR "${{PROJECT_BINARY_DIR}}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${{BUILD_BUNDLE_DIR}}" CACHE PATH "..." FORCE)
endif()
install(CODE "file(REMOVE_RECURSE \\\"${{CMAKE_INSTALL_PREFIX}}/\\\")" COMPONENT Runtime)
foreach(bundled_library ${{PLUGIN_BUNDLED_LIBRARIES}})
  install(FILES "${{bundled_library}}" DESTINATION "${{CMAKE_INSTALL_PREFIX}}/lib" COMPONENT Runtime)
endforeach()
''')
        configured = subprocess.run(
            ["cmake", "-S", str(root), "-B", str(root / "build")],
            text=True, capture_output=True, timeout=20,
        )
        return root, payload, configured

    def install(self, root):
        completed = subprocess.run(
            ["cmake", "--install", str(root / "build"), "--component", "Runtime"],
            text=True, capture_output=True, timeout=20,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def test_original_default_prefix_leaves_runtime_outside_app_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root, _, configured = self.make_project(directory, fixed=False)
            self.assertEqual(configured.returncode, 0, configured.stdout + configured.stderr)
            self.install(root)
            self.assertFalse((root / "build/bundle/lib" / RUNTIME).exists())
            self.assertTrue((root / "build/plugin/bundle/lib" / RUNTIME).exists())

    def test_parent_bundle_list_retains_runtime_after_clean_and_reinstall(self):
        with tempfile.TemporaryDirectory() as directory:
            root, payload, configured = self.make_project(directory)
            self.assertEqual(configured.returncode, 0, configured.stdout + configured.stderr)
            self.install(root)
            bundled = root / "build/bundle/lib" / RUNTIME
            self.assertEqual(bundled.read_bytes(), payload)
            (root / "build/bundle/stale").write_text("previous build")
            bundled.write_bytes(b"old runtime")
            self.install(root)
            self.assertEqual(bundled.read_bytes(), payload)
            self.assertFalse((root / "build/bundle/stale").exists())

    def test_missing_pinned_runtime_fails_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            _, _, configured = self.make_project(directory, runtime=False)
            self.assertNotEqual(configured.returncode, 0)
            self.assertIn("pinned flutter_js Linux QuickJS runtime is missing", configured.stderr)


if __name__ == "__main__":
    unittest.main()
