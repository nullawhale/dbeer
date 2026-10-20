#!/usr/bin/env python3
"""Exact-child native feasibility launcher. No native gate passes automatically."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone

REPO = Path(__file__).resolve().parents[3]
OUTPUT = REPO / "build/gpui-parity/native-runs"
GATES = (
    "gpu-rendering", "editor-input-ime", "virtualized-grid", "native-file-dialogs",
    "clipboard", "credential-roundtrip", "keyboard-focus", "accessibility-controls",
    "screen-reader", "light-dark-scaling",
)


def now():
    return datetime.now(timezone.utc).isoformat()


def write_json(path, value):
    # Publish only complete JSON. A hard-killed writer leaves an untrusted private
    # temporary file, never a truncated request/journal/completion record.
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    temporary = Path(temporary)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, path)  # Atomic, refuses replacement of existing evidence.
    finally:
        temporary.unlink(missing_ok=True)
    if os.name != "nt":
        directory = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try: os.fsync(directory)
        finally: os.close(directory)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def source_identity():
    # Hash only; never retain SQL/source text, credentials or a working diff.
    result = hashlib.sha256()
    sources = sorted((REPO / "prototypes/gpui/src").glob("*.rs"))
    sources += [REPO / "prototypes/gpui/Cargo.toml", REPO / "prototypes/gpui/Cargo.lock"]
    for path in sources:
        result.update(str(path.relative_to(REPO)).encode("utf-8"))
        result.update(b"\0")
        result.update(bytes.fromhex(digest(path)))
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5,
                              check=False).stdout.decode("ascii", errors="replace").strip()
    return {"revision": revision if re.fullmatch(r"[0-9a-f]{40,64}", revision) else "unavailable",
            "gpui_source_sha256": result.hexdigest()}


def machine_x64(header):
    """Inspect executable bytes, not its filename or a build claim."""
    if header[:4] == b"\x7fELF":
        return header[4:6] == b"\x02\x01" and header[18:20] == b"\x3e\x00"
    if header[:2] == b"MZ" and len(header) >= 64:
        offset = struct.unpack_from("<I", header, 60)[0]
        return header[offset:offset + 6] == b"PE\x00\x00\x64\x86"
    return False


def artifact(path, desktop, helper=False):
    if not path.is_absolute() or path.is_symlink():
        raise ValueError("Supply an absolute executable path without a final symlink")
    path = path.resolve(strict=True)
    expected = "dbeer-core" if helper else "dbeer-gpui"
    if desktop == "windows":
        expected += ".exe"
    if path.name != expected or not path.is_file():
        raise ValueError("Unexpected executable filename")
    with path.open("rb") as stream:
        header = stream.read(1024 * 1024)
    if not machine_x64(header):
        raise ValueError("The executable must be a native x64 PE or ELF image")
    if (desktop == "windows") != (header[:2] == b"MZ"):
        raise ValueError("Executable format does not match the requested desktop")
    if desktop != "windows" and not os.access(path, os.X_OK):
        raise ValueError("Executable permission is required")
    return path


def preflight(desktop):
    system = platform.system()
    expected = "Windows" if desktop == "windows" else "Linux"
    if system != expected:
        raise ValueError("This native run requires " + expected + "; this host is " + system)
    if platform.machine().lower() not in ("amd64", "x86_64") or sys.maxsize <= 2**32:
        raise ValueError("The desktop and Python must both be x64")
    if system == "Windows":
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.IsWow64Process2.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ushort),
                                          ctypes.POINTER(ctypes.c_ushort)]
        process_machine = ctypes.c_ushort()
        native_machine = ctypes.c_ushort()
        if not kernel.IsWow64Process2(ctypes.c_void_p(-1), ctypes.byref(process_machine),
                                    ctypes.byref(native_machine)) or native_machine.value != 0x8664:
            raise ValueError("A native x64 Windows host is required; ARM64 emulation is outside scope")
        version = sys.getwindowsversion()
        # Known Windows 11 client build family; reject future unknown OS families.
        import winreg
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                            r"SOFTWARE\Microsoft\Windows NT\CurrentVersion") as key:
            installation = winreg.QueryValueEx(key, "InstallationType")[0]
        if installation != "Client" or version.major != 10 or not 22000 <= version.build < 30000:
            raise ValueError("An owned Windows 11 client desktop is required")
        if ctypes.windll.shell32.IsUserAnAdmin():
            raise ValueError("Run as an ordinary unelevated desktop user")
        user32 = ctypes.WinDLL("user32", use_last_error=True)
        user32.OpenInputDesktop.restype = ctypes.c_void_p
        desktop_handle = user32.OpenInputDesktop(0, False, 1)
        if not desktop_handle:
            raise ValueError("An accessible interactive input desktop is required")
        user32.CloseDesktop.argtypes = [ctypes.c_void_p]
        user32.CloseDesktop(desktop_handle)
        return {"os": "Windows 11", "build": version.build, "session": "interactive"}
    release = dict(re.findall(r'^([A-Z_]+)=[\"\']?([^\n\"\']+)',
                              Path("/etc/os-release").read_text(), re.M))
    if release.get("ID") != "ubuntu" or release.get("VERSION_ID") != "24.04":
        raise ValueError("Ubuntu 24.04 is required")
    if os.geteuid() == 0:
        raise ValueError("Run as an ordinary desktop user")
    session = "wayland" if desktop == "wayland" else "x11"
    if os.environ.get("XDG_SESSION_TYPE") != session:
        raise ValueError("Log into the requested " + session + " desktop session")
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        raise ValueError("A user session D-Bus is required")
    if session == "wayland":
        name = os.environ.get("WAYLAND_DISPLAY", "")
        runtime = Path(os.environ.get("XDG_RUNTIME_DIR", "/nonexistent"))
        socket_path = Path(name) if Path(name).is_absolute() else runtime / name
        if not name or not runtime.is_absolute() or not socket_path.is_socket():
            raise ValueError("The Wayland session socket is absent")
    else:
        match = re.fullmatch(r":(\d+)(?:\.\d+)?", os.environ.get("DISPLAY", ""))
        if not match or not Path("/tmp/.X11-unix/X" + match[1]).is_socket():
            raise ValueError("A local X11 desktop socket is required")
    return {"os": "Ubuntu 24.04", "session": session}


def child_environment(root, helper, desktop):
    # Retain the owned user's desktop bus/GPU environment. Never repurpose HOME.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("DBEER_")}
    for name in ("config", "data", "state", "cache", "temp", "screenshots"):
        (root / name).mkdir(mode=0o700)
    env.update({"DBEER_GPUI_HELPER_PATH": str(helper),
                "DBEER_GPUI_SMOKE_OUTPUT": str(root / "screenshots")})
    if desktop == "windows":
        env.update({"LOCALAPPDATA": str(root / "data"), "APPDATA": str(root / "config"),
                    "TEMP": str(root / "temp"), "TMP": str(root / "temp")})
    else:
        env.update({"XDG_CONFIG_HOME": str(root / "config"), "XDG_DATA_HOME": str(root / "data"),
                    "XDG_STATE_HOME": str(root / "state"), "XDG_CACHE_HOME": str(root / "cache"),
                    "TMPDIR": str(root / "temp")})
    return env


def process_image(process):
    """Only query the child we created; never discover or attach by app name."""
    if process.poll() is not None:
        raise ValueError("The exact child exited before PID identity could be checked")
    if platform.system() == "Linux":
        return Path("/proc", str(process.pid), "exe").resolve(strict=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    kernel.OpenProcess.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel.QueryFullProcessImageNameW.argtypes = [ctypes.c_void_p, ctypes.c_uint32,
                                                ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_uint32)]
    handle = kernel.OpenProcess(0x1000, False, process.pid)
    if not handle:
        raise ValueError("Cannot query the exact child PID")
    try:
        size = ctypes.c_uint32(32768)
        buffer = ctypes.create_unicode_buffer(size.value)
        if not kernel.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
            raise ValueError("Cannot verify the exact child executable")
        return Path(buffer.value).resolve(strict=True)
    finally:
        kernel.CloseHandle(handle)


def stop_owned_child(process):
    # Popen retains ownership of this child (a process handle on Windows).
    # No process groups, name matching, taskkill, pkill, killall or descendants.
    if process is None or process.poll() is not None:
        return "already-exited"
    process.terminate()
    try:
        process.wait(timeout=5)
        return "terminated-owned-child"
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
        return "killed-owned-child"


def windows_private(path, create=False):
    """Owner-only run ACL, checked with the current token SID (no account names)."""
    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    pointer = ctypes.c_void_p
    dword = ctypes.c_uint32
    advapi.OpenProcessToken.argtypes = [pointer, dword, ctypes.POINTER(pointer)]
    advapi.GetTokenInformation.argtypes = [pointer, dword, pointer, dword, ctypes.POINTER(dword)]
    advapi.GetFileSecurityW.argtypes = [ctypes.c_wchar_p, dword, pointer, dword, ctypes.POINTER(dword)]
    advapi.GetSecurityDescriptorOwner.argtypes = [pointer, ctypes.POINTER(pointer), ctypes.POINTER(ctypes.c_int)]
    advapi.GetSecurityDescriptorDacl.argtypes = [pointer, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(pointer), ctypes.POINTER(ctypes.c_int)]
    advapi.EqualSid.argtypes = [pointer, pointer]
    advapi.GetAce.argtypes = [pointer, dword, ctypes.POINTER(pointer)]
    advapi.ConvertSidToStringSidW.argtypes = [pointer, ctypes.POINTER(pointer)]
    advapi.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes = [ctypes.c_wchar_p, dword, ctypes.POINTER(pointer), ctypes.POINTER(dword)]
    advapi.SetFileSecurityW.argtypes = [ctypes.c_wchar_p, dword, pointer]
    kernel.CloseHandle.argtypes = [pointer]
    kernel.LocalFree.argtypes = [pointer]
    token = pointer()
    if not advapi.OpenProcessToken(pointer(-1), 8, ctypes.byref(token)):
        return False
    try:
        size = dword()
        advapi.GetTokenInformation(token, 1, None, 0, ctypes.byref(size))
        user = ctypes.create_string_buffer(size.value)
        if not advapi.GetTokenInformation(token, 1, user, size, ctypes.byref(size)):
            return False
        user_sid = ctypes.cast(user, ctypes.POINTER(pointer))[0]
        if create:
            sid_text, descriptor = pointer(), pointer()
            try:
                if not advapi.ConvertSidToStringSidW(user_sid, ctypes.byref(sid_text)):
                    return False
                sddl = "D:P(A;OICI;FA;;;" + ctypes.wstring_at(sid_text) + ")"
                if not advapi.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, ctypes.byref(descriptor), None):
                    return False
                if not advapi.SetFileSecurityW(str(path), 4 | 0x80000000, descriptor):
                    return False
            finally:
                if sid_text: kernel.LocalFree(sid_text)
                if descriptor: kernel.LocalFree(descriptor)
        advapi.GetFileSecurityW(str(path), 1 | 4, None, 0, ctypes.byref(size))
        descriptor = ctypes.create_string_buffer(size.value)
        if not advapi.GetFileSecurityW(str(path), 1 | 4, descriptor, size, ctypes.byref(size)):
            return False
        owner, dacl = pointer(), pointer()
        defaulted, present = ctypes.c_int(), ctypes.c_int()
        if not advapi.GetSecurityDescriptorOwner(descriptor, ctypes.byref(owner), ctypes.byref(defaulted)) or not advapi.EqualSid(owner, user_sid):
            return False
        if not advapi.GetSecurityDescriptorDacl(descriptor, ctypes.byref(present), ctypes.byref(dacl), ctypes.byref(defaulted)) or not present.value or not dacl:
            return False
        # ACL header AceCount is at byte offset 4. Accept only one owner Allow ACE.
        if ctypes.c_ushort.from_address(dacl.value + 4).value != 1:
            return False
        ace = pointer()
        if not advapi.GetAce(dacl, 0, ctypes.byref(ace)) or ctypes.c_ubyte.from_address(ace.value).value != 0:
            return False
        mask = dword.from_address(ace.value + 4).value
        return bool(mask & 0x1f01ff == 0x1f01ff and advapi.EqualSid(pointer(ace.value + 8), user_sid))
    finally:
        kernel.CloseHandle(token)


def private_path(path, directory=False):
    metadata = path.lstat()
    if (not stat.S_ISDIR(metadata.st_mode) if directory else not stat.S_ISREG(metadata.st_mode)):
        raise ValueError("Probe paths must be regular owned files/directories")
    if os.name == "nt":
        if getattr(metadata, "st_file_attributes", 0) & 0x400 or not windows_private(path):
            raise ValueError("Probe path does not have its owned private ACL")
    elif metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
        raise ValueError("Probe paths must be private and owned by the current user")


CREDENTIAL_FIELDS = {"completed", "created", "read_back", "replaced", "cleanup_attempted",
                     "cleanup_verified", "collision", "failed"}
EVIDENCE_MAX_DEPTH = 64


def strict_json(path, limit=4096):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("Duplicate report field")
            result[key] = value
        return result
    private_path(path)
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Probe evidence exceeds its limit")
    try:
        value = json.loads(data, object_pairs_hook=pairs)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise ValueError("Malformed probe evidence") from error
    # Bound container nesting independently of the interpreter's recursion limit.
    pending = [(value, 1)]
    while pending:
        current, depth = pending.pop()
        if isinstance(current, (dict, list)):
            if depth > EVIDENCE_MAX_DEPTH:
                raise ValueError("Malformed probe evidence")
            children = current.values() if isinstance(current, dict) else current
            pending.extend((child, depth + 1) for child in children)
    return value


def make_request(root):
    token = uuid.uuid4().hex
    request = {"version": 1, "root": str(root.resolve()), "token": token,
               "account": "dbeer-feasibility-" + token}
    path = root / "probe-request.json"
    write_json(path, request)
    return path


def validated_request(path):
    if not path.is_absolute() or path.name != "probe-request.json":
        raise ValueError("Supply an absolute owned probe request")
    if path.parent != path.parent.resolve():
        raise ValueError("Symlinked probe roots are refused")
    private_path(path.parent, directory=True)
    private_path(path.parent / "fixtures", directory=True)
    request = strict_json(path)
    if (not isinstance(request, dict) or set(request) != {"version", "root", "token", "account"}
            or type(request["version"]) is not int or request["version"] != 1
            or not isinstance(request["token"], str) or not re.fullmatch(r"[0-9a-f]{32}", request["token"])
            or request["account"] != "dbeer-feasibility-" + request["token"]
            or request["root"] != str(path.parent.resolve())
            or not path.parent.resolve().is_relative_to(OUTPUT.resolve())):
        raise ValueError("Probe request ownership or reserved account is invalid")
    return request


def make_context(request_path, executable, desktop):
    request = validated_request(request_path)
    context = {"schema_version": 1, "executable": str(executable), "executable_sha256": digest(executable),
               "account": request["account"], "root": request["root"], "desktop": desktop,
               "request_sha256": digest(request_path)}
    write_json(request_path.parent / "credential-context.json", context)
    return context


def validated_context(request_path, executable):
    request = validated_request(request_path)
    context = strict_json(request_path.parent / "credential-context.json")
    if (not isinstance(context, dict) or set(context) != {"schema_version", "executable", "executable_sha256", "account", "root", "desktop", "request_sha256"}
            or type(context["schema_version"]) is not int or context["schema_version"] != 1
            or context["account"] != request["account"] or context["root"] != request["root"]
            or context["request_sha256"] != digest(request_path) or context["executable"] != str(executable)
            or context["executable_sha256"] != digest(executable) or context["desktop"] not in ("windows", "wayland", "x11")):
        raise ValueError("Credential recovery context does not match the original request/artifact")
    return context


def validated_claim(request_path):
    request = validated_request(request_path)
    claim = strict_json(request_path.parent / "credential-owned.json", limit=1024)
    if (not isinstance(claim, dict) or set(claim) != {"version", "token", "account", "pid"}
            or type(claim["version"]) is not int or claim["version"] != 1
            or claim["token"] != request["token"] or claim["account"] != request["account"]
            or type(claim["pid"]) is not int or claim["pid"] <= 0):
        raise ValueError("No valid native-created credential ownership grant")
    worker = strict_json(request_path.parent / ("credential-worker-" + str(claim["pid"]) + ".json"))
    if (not isinstance(worker, dict) or worker.get("mode") != "probe" or worker.get("pid") != claim["pid"]
            or worker.get("account") != request["account"] or worker.get("pid_image_verified") is not True):
        raise ValueError("Credential ownership grant has no matching exact probe worker")
    return claim


def credential_command(executable, request_path, env, cleanup=False, timeout=15):
    process = None
    result = {"outcome": "refused", "pid_image_verified": False}
    flag = "--feasibility-credential-cleanup" if cleanup else "--feasibility-credential-probe"
    try:
        request = validated_request(request_path)
        context = validated_context(request_path, executable)
        if cleanup: validated_claim(request_path)
        # Credential subprocess output is discarded, including native library errors.
        process = subprocess.Popen([str(executable), flag, str(request_path)], cwd=request_path.parent,
                                   env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, start_new_session=os.name != "nt",
                                   creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0)
        result["pid"] = process.pid
        if not process_image(process).samefile(executable):
            raise ValueError("Credential child image mismatch")
        result["pid_image_verified"] = True
        write_json(request_path.parent / ("credential-worker-" + str(process.pid) + ".json"),
                   {**context, "pid": process.pid, "mode": "cleanup" if cleanup else "probe",
                    "pid_image_verified": True, "started_utc": now()})
        # Native worker waits for this exact-child identity handshake before any store access.
        go = request_path.parent / ("credential-go-" + str(process.pid))
        temporary = go.with_suffix(".pending")
        descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        try:
            with os.fdopen(descriptor, "w", encoding="ascii") as stream:
                stream.write(request["token"])
                stream.flush()
                os.fsync(stream.fileno())
            # Atomic publication without replacing a prior identity marker.
            os.link(temporary, go)
        finally:
            temporary.unlink(missing_ok=True)
        code = process.wait(timeout=timeout)
        name = "credential-cleanup-" + str(process.pid) + ".json" if cleanup else "credential-probe.json"
        report = strict_json(request_path.parent / name)
        if (not isinstance(report, dict) or set(report) != {"version", "pid", "native_acceptance", "result"}
                or type(report["version"]) is not int or report["version"] != 1
                or type(report["pid"]) is not int or report["pid"] != process.pid
                or report["native_acceptance"] != "not-run" or not isinstance(report["result"], dict)
                or set(report["result"]) != CREDENTIAL_FIELDS
                or any(type(value) is not bool for value in report["result"].values())):
            raise ValueError("Credential report shape is invalid")
        result["result"] = report["result"]
        result["outcome"] = "completed" if code == 0 and report["result"]["completed"] else "probe-failed"
    except KeyboardInterrupt:
        result["outcome"] = "cancelled"
    except subprocess.TimeoutExpired:
        result["outcome"] = "timeout"
    except (OSError, ValueError):
        # Never copy arbitrary native errors, file contents or secret values.
        result["outcome"] = "refused-or-invalid-report"
    finally:
        previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            try:
                result["process_cleanup"] = stop_owned_child(process)
            except (OSError, subprocess.TimeoutExpired):
                result["process_cleanup"] = "failed-owned-child-may-still-be-running"
                result["outcome"] = "cleanup-failed"
        finally:
            signal.signal(signal.SIGINT, previous)
        if process is not None:
            try:
                write_json(request_path.parent / ("credential-worker-" + str(process.pid) + "-finished.json"),
                           {"completed": True, "pid": process.pid, "worker": result})
            except (OSError, ValueError):
                result["worker_completion_evidence"] = "write-failed"
    return result


def valid_event(event, expected_pid):
    if (not isinstance(event, dict) or set(event) != {"kind", "pid", "facts"}
            or type(event["pid"]) is not int or event["pid"] != expected_pid or not isinstance(event["facts"], dict)):
        return False
    facts = event["facts"]
    if event["kind"] == "dialog-requested":
        return set(facts) == {"save"} and type(facts["save"]) is bool
    if event["kind"] == "dialog-result":
        return (set(facts) == {"save", "outcome", "selected_file_read", "destination_written"}
                and type(facts["save"]) is bool and facts["outcome"] in
                ("fixture-selected", "outside-fixture-rejected", "cancelled", "error-or-timeout")
                and facts["selected_file_read"] is False and facts["destination_written"] is False)
    if event["kind"] == "clipboard":
        if facts == {"outcome": "not-run-no-readable-original"}: return True
        return (set(facts) == {"marker_matched", "restore_requested", "restored_item_matched", "native_acceptance"}
                and facts["native_acceptance"] == "not-run"
                and all(type(facts[key]) is bool for key in ("marker_matched", "restore_requested", "restored_item_matched")))
    if event["kind"] != "scene-grid-facts": return False
    integers = {"total_rows", "visible_row_start", "visible_row_end", "visible_column_start",
                "visible_column_end", "painted_quad_count", "capture_elapsed_ms"}
    if (set(facts) != integers | {"scene_readback_supported", "scene_pixels", "native_acceptance"}
            or any(type(facts[key]) is not int or facts[key] < 0 for key in integers)
            or facts["total_rows"] != 1000 or not 0 <= facts["visible_row_start"] <= facts["visible_row_end"] <= 1000
            or not 0 <= facts["visible_column_start"] <= facts["visible_column_end"] <= 8
            or type(facts["scene_readback_supported"]) is not bool or facts["native_acceptance"] != "not-run"):
        return False
    pixels = facts["scene_pixels"]
    return ((pixels is None and not facts["scene_readback_supported"])
            or (facts["scene_readback_supported"] and isinstance(pixels, list) and len(pixels) == 2
                and all(type(size) is int and 0 < size <= 32768 for size in pixels)))


def pid_running(pid):
    if type(pid) is not int or pid <= 0:
        return True  # An invalid identity cannot authorize a recovery write.
    if os.name != "nt":
        return Path("/proc", str(pid)).exists()
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    kernel.OpenProcess.restype = ctypes.c_void_p
    kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.OpenProcess(0x100000 | 0x1000, False, pid)
    if not handle:
        return ctypes.get_last_error() != 87  # Only invalid PID proves absence.
    try:
        return kernel.WaitForSingleObject(handle, 0) != 0
    finally:
        kernel.CloseHandle(handle)


def collect_ui(root, expected_pid):
    report = strict_json(root / "probe-ui.json")
    if (not isinstance(report, dict) or set(report) != {"version", "pid", "completed", "event_count", "grid_rows", "native_acceptance"}
            or report["version"] != 1 or type(report["pid"]) is not int or report["pid"] != expected_pid
            or report["completed"] is not True or type(report["event_count"]) is not int
            or not 0 <= report["event_count"] <= 256 or report["grid_rows"] != 1000
            or report["native_acceptance"] != "not-run"):
        raise ValueError("Incomplete or invalid probe UI summary")
    # Events contain only fixed metadata from the probe. Bound retention and verify
    # each record belongs to this exact UI process; never ingest editor/cell text.
    private_path(root / "probe-events.jsonl")
    with (root / "probe-events.jsonl").open("rb") as stream:
        lines = stream.read(512 * 1024 + 1)
    if len(lines) > 512 * 1024:
        raise ValueError("Probe event evidence exceeds its limit")
    if len(lines.splitlines()) != report["event_count"]:
        raise ValueError("Probe event count does not match its completed summary")
    for line in lines.splitlines():
        try:
            pairs = json.loads(line, object_pairs_hook=lambda items: items)
            def unpack(items):
                if not isinstance(items, list): return items
                if all(isinstance(item, tuple) and len(item) == 2 for item in items):
                    if len({key for key, _ in items}) != len(items): raise ValueError("Duplicate event field")
                    return {key: unpack(value) for key, value in items}
                return [unpack(value) for value in items]
            event = unpack(pairs)
            if not valid_event(event, expected_pid): raise ValueError("Invalid probe event schema or PID")
        except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
            raise ValueError("Malformed probe event") from error
    return {"completed": True, "event_count": report["event_count"], "grid_rows": 1000,
            "native_acceptance": "not-run", "events_sha256": digest(root / "probe-events.jsonl")}


def recover(args):
    preflight(args.desktop)
    executable = artifact(args.executable, args.desktop)
    request = validated_request(args.request)
    context = validated_context(args.request, executable)
    if context["desktop"] != args.desktop:
        raise ValueError("Recovery requires the original desktop")
    # Durable worker authorization exists before the go marker/native mutation.
    # It survives a killed harness even when no terminal summary was written.
    for path in args.request.parent.glob("credential-worker-*.json"):
        if path.name.endswith("-finished.json"): continue
        worker = strict_json(path)
        if (not isinstance(worker, dict) or set(worker) != set(context) | {"pid", "mode", "pid_image_verified", "started_utc"}
                or any(worker[key] != value for key, value in context.items())
                or type(worker["pid"]) is not int or worker["pid"] <= 0 or worker["mode"] not in ("probe", "cleanup")
                or worker["pid_image_verified"] is not True or not isinstance(worker["started_utc"], str)):
            raise ValueError("Invalid durable credential worker identity")
        terminal = args.request.parent / ("credential-worker-" + str(worker["pid"]) + "-finished.json")
        confirmed_exit = False
        if terminal.exists():
            try:
                finished = strict_json(terminal)
                if (isinstance(finished, dict) and set(finished) == {"completed", "pid", "worker"}
                        and finished["completed"] is True and finished["pid"] == worker["pid"]
                        and isinstance(finished["worker"], dict)):
                    confirmed_exit = finished["worker"].get("process_cleanup") in (
                        "already-exited", "terminated-owned-child", "killed-owned-child")
            except (OSError, ValueError):
                pass  # Malformed terminal evidence authorizes nothing; check recorded PID below.
        # A reused live PID conservatively blocks; never signal that process.
        if not confirmed_exit and pid_running(worker["pid"]):
            raise ValueError("Prior worker termination is unconfirmed; inspect its exact recorded PID first")
    if not (args.request.parent / "credential-owned.json").exists():
        result = {"outcome": "not-needed-no-ownership-grant", "native_mutation_performed": False}
        report_path = args.request.parent / ("recovery-" + uuid.uuid4().hex + ".json")
        write_json(report_path, {"completed": True, "native_acceptance": "not-run", "account": request["account"],
                                 "finished_utc": now(), "credential_cleanup": result})
        print("Completed credential recovery summary: " + str(report_path))
        return 0
    validated_claim(args.request)
    env = {key: value for key, value in os.environ.items() if not key.startswith("DBEER_")}
    env.update({"DBEER_FEASIBILITY_ROOT": request["root"], "DBEER_FEASIBILITY_TOKEN": request["token"]})
    result = credential_command(executable, args.request, env, cleanup=True)
    report_path = args.request.parent / ("recovery-" + uuid.uuid4().hex + ".json")
    write_json(report_path, {"completed": True, "native_acceptance": "not-run", "account": request["account"],
                             "finished_utc": now(), "credential_cleanup": result})
    print("Completed credential recovery summary: " + str(report_path))
    return 0 if result.get("result", {}).get("cleanup_verified") and result["outcome"] == "completed" else 1


def run(args):
    cleanup = {"failed": False}
    try:
        result = _run_with_cleanup(args, cleanup)
    except BaseException:
        # Preserve the cleanup-failure exit override, including pending errors.
        if not cleanup["failed"]:
            raise
        result = 1
    return 1 if cleanup["failed"] else result


def _run_with_cleanup(args, cleanup):
    OUTPUT.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix=args.desktop + "-", dir=OUTPUT)).resolve()
    root.chmod(0o700)
    if os.name == "nt" and not windows_private(root, create=True):
        raise ValueError("Cannot create an owner-only disposable run ACL")
    summary = {"schema_version": 1, "started_utc": now(), "desktop": args.desktop,
               "mode": args.command, "completed": False, "outcome": "refused",
               "native_acceptance": "not-run", "gates": {key: "not-run" for key in GATES},
               "registry_modified": False, "run_directory": str(root),
               "harness_sha256": digest(Path(__file__)),
               "cargo_lock_sha256": digest(REPO / "prototypes/gpui/Cargo.lock")}
    process = None
    request_path = None
    recovery_needed = False
    env = None
    executable = None
    try:
        summary["preflight"] = preflight(args.desktop)
        summary["source"] = source_identity()
        executable = artifact(args.executable, args.desktop)
        helper = artifact(args.helper, args.desktop, helper=True)
        summary["artifacts"] = {"executable": str(executable), "executable_sha256": digest(executable),
                                "helper": str(helper), "helper_sha256": digest(helper)}
        if args.command == "preflight":
            summary["outcome"] = "preflight-only"
            return 0
        env = child_environment(root, helper, args.desktop)
        fixtures = root / "fixtures"
        fixtures.mkdir(mode=0o700)
        for name in ("sql.json", "grid.json"):
            source = REPO / "prototypes/gpui/parity/fixtures" / name
            (fixtures / name).write_bytes(source.read_bytes())
        write_json(root / "observations.json", {
            "schema_version": 1, "observer": "", "run_directory": str(root),
            "instructions": "Record actual target observations and relative evidence paths. "
                            "Compilation, metadata and internal smoke checks do not pass these gates.",
            "gates": [{"id": key, "status": "not-run", "observed_utc": "", "observation": "",
                       "evidence": []} for key in GATES]})
        arguments = [str(executable)]
        if args.command == "smoke":
            arguments.append("--smoke-test")
        else:
            (fixtures / "feasibility.sql").write_text("SELECT 'probe \U0001f600 e\u0301' AS synthetic;\r\n-- No database connection\n", encoding="utf-8")
            request_path = make_request(root)
            request = validated_request(request_path)
            env["DBEER_FEASIBILITY_ROOT"] = request["root"]
            env["DBEER_FEASIBILITY_TOKEN"] = request["token"]
            summary["credential_account"] = validated_request(request_path)["account"]
            make_context(request_path, executable, args.desktop)
            recovery_needed = True  # Recorded before the first possible native store write.
            summary["credential_probe"] = credential_command(executable, request_path, env)
            if summary["credential_probe"].get("result", {}).get("collision"):
                recovery_needed = False
            if summary["credential_probe"]["outcome"] == "cancelled":
                summary["outcome"] = "cancelled"
                return 130
            if summary["credential_probe"].get("process_cleanup") == "failed-owned-child-may-still-be-running":
                summary["outcome"] = "credential-recovery-required"
                return 1
            arguments += ["--feasibility-probe", str(request_path)]
        with (root / "application.log").open("xb") as log:
            process = subprocess.Popen(arguments, cwd=fixtures, env=env, stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=os.name != "nt",
                                       creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0)
            actual = process_image(process)
            if not actual.samefile(executable):
                raise ValueError("Child PID executable identity does not match")
            summary["pid"] = process.pid
            summary["pid_image_verified"] = True
            write_json(root / "target.json", {"pid": process.pid, "executable": str(executable),
                                             "sha256": digest(executable), "started_utc": now()})
            print("Exact target PID: " + str(process.pid), flush=True)
            print("Evidence directory: " + str(root), flush=True)
            try:
                summary["exit_code"] = process.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                summary["outcome"] = "timeout"
                return 1
        if digest(executable) != summary["artifacts"]["executable_sha256"]:
            raise ValueError("Executable changed during this run")
        if summary["exit_code"] != 0:
            summary["outcome"] = "application-failed"
            return 1
        if args.command == "smoke":
            result = root / "screenshots/summary.txt"
            match = re.fullmatch(r"Native smoke: ([1-9]\d*) checks passed; completed\.\n"
                                 r"Snapshots: dark\.png, light\.png\n", result.read_text()) if result.is_file() else None
            if not match or not all((root / "screenshots" / name).is_file()
                                    for name in ("dark.png", "light.png")):
                raise ValueError("No completed nonempty internal smoke summary; build with native-smoke")
            summary["internal_smoke"] = {"checks": int(match[1]), "completed": True,
                                         "scope": "GPUI scene/internal actions only"}
        if args.command == "operator":
            summary["probe_ui"] = collect_ui(root, process.pid)
            if summary["credential_probe"]["outcome"] != "completed":
                summary["outcome"] = "probe-failed"
                return 1
        summary["outcome"] = "review-required"
        return 0
    except KeyboardInterrupt:
        summary["outcome"] = "cancelled"
        return 130
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        # Do not print app logs, environment, database settings or native errors.
        summary["reason"] = str(error) if isinstance(error, ValueError) else "Local filesystem/process operation failed"
        return 1
    finally:
        # A second Ctrl+C must not interrupt owned-child cleanup or summary write.
        previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            cleanup_failed = False
            try:
                summary["cleanup"] = stop_owned_child(process)
            except (OSError, subprocess.TimeoutExpired):
                summary["cleanup"] = "failed-owned-child-may-still-be-running"
                summary["outcome"] = "cleanup-failed"
                cleanup_failed = True
            if (recovery_needed and request_path is not None
                    and summary.get("credential_probe", {}).get("process_cleanup") != "failed-owned-child-may-still-be-running"
                    and not (root / "credential-owned.json").exists()):
                # Native worker cannot write until its durable absence/ownership grant.
                recovery_needed = False
                summary["credential_cleanup"] = {"outcome": "not-needed-no-ownership-grant"}
                summary["credential_recovery_required"] = False
            if recovery_needed and request_path is not None and env is not None:
                prior_live = summary.get("credential_probe", {}).get("process_cleanup") == "failed-owned-child-may-still-be-running"
                summary["credential_cleanup"] = ({"outcome": "blocked-prior-worker-may-be-running"} if prior_live
                    else credential_command(executable, request_path, env, cleanup=True))
                summary["credential_recovery_required"] = not (
                    summary["credential_cleanup"].get("result", {}).get("cleanup_verified")
                    and summary["credential_cleanup"]["outcome"] == "completed")
                if summary["credential_recovery_required"]:
                    summary["outcome"] = "credential-recovery-required"
                    cleanup_failed = True
            summary["completed"] = True
            summary["finished_utc"] = now()
            write_json(root / "summary.json", summary)
            print("Completed run summary: " + str(root / "summary.json"), flush=True)
            if "reason" in summary:
                print(summary["reason"], file=sys.stderr)
        finally:
            signal.signal(signal.SIGINT, previous)
        cleanup["failed"] = cleanup_failed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("preflight", "smoke", "operator", "recover"))
    parser.add_argument("--desktop", required=True, choices=("windows", "wayland", "x11"))
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--request", type=Path)
    args = parser.parse_args()
    if not 10 <= args.timeout <= 3600:
        parser.error("--timeout must be between 10 and 3600 seconds")
    if args.command == "recover":
        if args.request is None:
            parser.error("recover requires the original --request path")
        try:
            return recover(args)
        except (OSError, ValueError):
            print("Credential recovery refused; retain the original account/request and evidence.", file=sys.stderr)
            return 1
    if args.request is not None:
        parser.error("--request is valid only for recover")
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
