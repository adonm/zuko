#!/usr/bin/env python3
"""Patch known desktop issues in pinned Flutter plugins."""

from __future__ import annotations

import json
import pathlib
import sys
import urllib.parse
import urllib.request


def package_root(flutter_root: pathlib.Path, name: str) -> pathlib.Path:
    config_path = flutter_root / ".dart_tool/package_config.json"
    config = json.loads(config_path.read_text())
    package = next(
        (entry for entry in config["packages"] if entry["name"] == name),
        None,
    )
    if package is None:
        raise SystemExit(f"{name} is missing from Flutter package_config.json")

    root_uri = package["rootUri"]
    parsed = urllib.parse.urlparse(root_uri)
    if parsed.scheme == "file":
        return pathlib.Path(urllib.request.url2pathname(parsed.path))
    return (config_path.parent / urllib.request.url2pathname(root_uri)).resolve()


def require_version(root: pathlib.Path, name: str, version: str) -> None:
    if f"version: {version}" not in (root / "pubspec.yaml").read_text():
        raise SystemExit(f"remove the {name} {version} workaround before upgrading")


def patch_file(
    path: pathlib.Path,
    replacements: list[tuple[str, str]],
) -> None:
    contents = path.read_text()
    changed = False
    for old, new in replacements:
        if new in contents:
            continue
        if old not in contents:
            raise SystemExit(f"unsupported pinned plugin layout: {path}")
        contents = contents.replace(old, new, 1)
        changed = True
    if changed:
        path.write_text(contents)
        print(f"patched {path}")


def patch_iroh_flutter(flutter_root: pathlib.Path) -> None:
    root = package_root(flutter_root, "iroh_flutter")
    require_version(root, "iroh_flutter", "1.0.1")
    for path, library_name in [
        (root / "linux/CMakeLists.txt", "libirohdart_ffi.so"),
        (root / "windows/CMakeLists.txt", "irohdart_ffi.dll"),
    ]:
        patch_file(
            path,
            [
                (
                    f'"$<TARGET_FILE_DIR:${{PLUGIN_NAME}}>/{library_name}"',
                    '"${${PLUGIN_NAME}_cargokit_lib}"',
                ),
            ],
        )


def patch_jni(flutter_root: pathlib.Path) -> None:
    root = package_root(flutter_root, "jni")
    require_version(root, "jni", "1.0.0")
    patch_file(
        root / "android/build.gradle",
        [("ndkVersion flutter.ndkVersion", 'ndkVersion "29.0.14206865"')],
    )
    patch_file(
        root / "src/CMakeLists.txt",
        [
            (
                """    else()
        # Flutter Plugin Build: Try to find JNI, but don't fail if missing
        find_package(JNI COMPONENTS JVM)
        if (JNI_FOUND)
            set(JNI_AVAILABLE TRUE)
        endif()
    endif()
""",
                """    else()
        # Zuko does not use desktop JNI; only build it when explicitly required.
    endif()
""",
            ),
        ],
    )


def patch_secure_storage_linux(flutter_root: pathlib.Path) -> None:
    # Backport upstream PR #1163 at f28ab833 until it reaches a pub release.
    root = package_root(flutter_root, "flutter_secure_storage_linux")
    require_version(root, "flutter_secure_storage_linux", "3.0.1")
    secret = root / "linux/include/Secret.hpp"
    patch_file(
        secret,
        [
            (
                "#include <memory>\n",
                "#include <memory>\n#include <stdexcept>\n#include <string>\n",
            ),
            (
                """static inline void secret_cleanup_free(gchar **p) { secret_password_free(*p); }

class SecretStorage {
""",
                """static inline void secret_cleanup_free(gchar **p) { secret_password_free(*p); }

class LibsecretError : public std::runtime_error {
  std::string error_code;

  static const char *codeFromGError(const GError *error) {
    if (error == nullptr) {
      return "Libsecret error";
    }

    if (g_error_matches(error, SECRET_ERROR, SECRET_ERROR_IS_LOCKED)) {
      return "KeyringLocked";
    }

    if (g_error_matches(error, SECRET_ERROR, SECRET_ERROR_NO_SUCH_OBJECT)) {
      return "SecretNotFound";
    }

    return "Libsecret error";
  }

  static std::string messageWithContext(const char *context,
                                        const char *message) {
    if (message == nullptr) {
      return context == nullptr ? "Libsecret error" : context;
    }

    if (context == nullptr || context[0] == '\\0') {
      return message;
    }

    std::string result(context);
    result += ": ";
    result += message;
    return result;
  }

public:
  explicit LibsecretError(const char *message)
      : LibsecretError("Libsecret error", message) {}

  LibsecretError(const char *code, const char *message)
      : std::runtime_error(
            message == nullptr
                ? (code == nullptr ? "Libsecret error" : code)
                : message),
        error_code(code == nullptr ? "Libsecret error" : code) {}

  LibsecretError(const char *context, const GError *error)
      : std::runtime_error(messageWithContext(
            context, error == nullptr ? nullptr : error->message)),
        error_code(codeFromGError(error)) {}

  const char *code() const { return error_code.c_str(); }
};

class SecretStorage {
""",
            ),
            (
                """  void deleteItem(const char *key) {
    try {
      nlohmann::json root = readFromKeyring();
      if (root.is_null()) {
          return;
      }
      root.erase(key);
      storeToKeyring(root);
    } catch (const std::exception& e) {
        return;
    }
  }
""",
                """  void deleteItem(const char *key) {
    nlohmann::json root = readFromKeyring();
    if (root.is_null()) {
      return;
    }
    root.erase(key);
    storeToKeyring(root);
  }
""",
            ),
            (
                """    if (err) {
      throw err->message;
    }

    return result;
""",
                """    if (err) {
      throw LibsecretError("secret_password_storev_sync", err);
    }

    return result;
""",
            ),
            (
                """    if (err) {
      throw err->message;
    }
    if(result != NULL && strcmp(result, "") != 0){
""",
                """    if (err) {
      throw LibsecretError("secret_password_lookupv_sync", err);
    }
    if(result != NULL && strcmp(result, "") != 0){
""",
            ),
            (
                """  // Ensures the default keyring is accessible. Uses the libsecret service API
  // to detect a locked keyring and throw a distinct "KeyringLocked" sentinel so
  // callers can surface the right error code to Dart.
  // Loading all collections also resolves cold-keyring lookup failures:
  // https://gitlab.gnome.org/GNOME/gnome-keyring/-/issues/89
""",
                """  // Ensures the default keyring is accessible and distinguishes a locked
  // collection from other storage errors. Do not load all collections here:
  // some Secret Service backends fail when an unrelated stale item exists.
""",
            ),
            (
                """    SecretService *service = secret_service_get_sync(
        static_cast<SecretServiceFlags>(SECRET_SERVICE_OPEN_SESSION | SECRET_SERVICE_LOAD_COLLECTIONS),
        nullptr, &err);
""",
                """    SecretService *service = secret_service_get_sync(
        SECRET_SERVICE_OPEN_SESSION, nullptr, &err);
""",
            ),
            (
                """    if (!service) {
      throw "KeyringLocked";
    }
""",
                """    if (!service) {
      throw LibsecretError("secret_service_get_sync", err);
    }
""",
            ),
            (
                """    if (!collection) {
      g_object_unref(service);
      throw "KeyringLocked";
    }
""",
                """    if (!collection) {
      g_object_unref(service);
      throw LibsecretError("secret_collection_for_alias_sync", err);
    }
""",
            ),
            (
                """    GList *to_unlock = g_list_append(nullptr, collection);
    GList *unlocked_out = nullptr;
    gint n = secret_service_unlock_sync(service, to_unlock, nullptr, &unlocked_out, nullptr);
    g_list_free(to_unlock);
    if (unlocked_out) {
      g_list_free_full(unlocked_out, g_object_unref);
    }
    g_object_unref(collection);
    g_object_unref(service);

    if (n == 0) {
      throw "KeyringLocked";
    }
""",
                """    g_object_unref(collection);
    g_object_unref(service);

    throw LibsecretError("KeyringLocked", "Keyring is locked");
""",
            ),
        ],
    )

    plugin = root / "linux/flutter_secure_storage_linux_plugin.cc"
    patch_file(
        plugin,
        [
            (
                """    catch (const std::exception& e)
    {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "StorageError", e.what(), nullptr));
    }
""",
                """    catch (const LibsecretError& e)
    {
      g_autofree gchar *safe = g_utf8_make_valid(e.what(), -1);
      g_warning("libsecret_error: %s", safe);
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          e.code(), safe, nullptr));
    }
    catch (const std::exception& e)
    {
      g_autofree gchar *safe = g_utf8_make_valid(e.what(), -1);
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "StorageError", safe, nullptr));
    }
""",
            ),
        ],
    )


def main() -> None:
    flutter_root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "flutter").resolve()
    patch_iroh_flutter(flutter_root)
    patch_jni(flutter_root)
    patch_secure_storage_linux(flutter_root)


if __name__ == "__main__":
    main()
