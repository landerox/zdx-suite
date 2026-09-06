#!/usr/bin/env python3
"""Private filesystem primitives for the local Zsh installer (Python 3.8+)."""

import hashlib
import json
import os
import secrets
import signal
import stat
import sys


class InstallError(Exception):
    """A validated installation cannot proceed safely."""


def _zdx_install_identity(info):
    # Creating a child changes directory link counts, not the directory's identity.
    links = 0 if stat.S_ISDIR(info.st_mode) else info.st_nlink
    return [info.st_dev, info.st_ino, info.st_uid, info.st_mode, links]


def _zdx_install_path(value):
    if not value or not os.path.isabs(value) or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise InstallError("installation paths must be absolute and contain no control characters")
    return os.path.normpath(value)


def _zdx_install_safe(info, path, directory=False, private=False, own=False):
    mode = info.st_mode
    if info.st_uid not in ((os.getuid(),) if own else (0, os.getuid())):
        raise InstallError("untrusted owner: " + path)
    if directory:
        if not stat.S_ISDIR(mode):
            raise InstallError("expected a real directory: " + path)
        sticky_root = info.st_uid == 0 and mode & stat.S_ISVTX
        if mode & 0o022 and not sticky_root:
            raise InstallError("directory is writable by group or others: " + path)
    else:
        if not stat.S_ISREG(mode) or info.st_nlink != 1:
            raise InstallError("expected a regular file with one hard link: " + path)
        if mode & (0o077 if private else 0o022):
            raise InstallError("unsafe file permissions: " + path)
        if not mode & 0o444:
            raise InstallError("file is not readable: " + path)


def _zdx_install_inspect(path, nodes, optional=False, directory=False, private=False, own=False):
    """Inspect every component without following symlinks; remember object identity."""
    current = "/"
    parts = path.strip("/").split("/") if path != "/" else []
    _zdx_install_safe(os.lstat("/"), "/", directory=True)
    for index, part in enumerate(parts):
        current = os.path.join(current, part)
        final = index == len(parts) - 1
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            if optional:
                nodes[current] = None
                return None
            raise InstallError("required path does not exist: " + current)
        _zdx_install_safe(info, current, directory=directory if final else True,
                          private=private if final else False, own=own if final else False)
        nodes[current] = _zdx_install_identity(info)
    return os.lstat(path)


def _zdx_install_read(path, nodes, private=False, own=False):
    info = _zdx_install_inspect(path, nodes, private=private, own=own)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        if _zdx_install_identity(os.fstat(stream.fileno())) != _zdx_install_identity(info):
            raise InstallError("file changed during validation: " + path)
        data = stream.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise InstallError("installer input exceeds 1 MiB: " + path)
    return data


def _zdx_install_plan(inputs, announce=False):
    source, home, omz, custom, profile = [_zdx_install_path(value) for value in inputs]
    original_home = home
    home = os.path.realpath(home)
    source = os.path.realpath(source)

    def home_path(value):
        if value == original_home or value.startswith(original_home.rstrip("/") + "/"):
            return home + value[len(original_home):]
        return value

    # HOME is an explicit anchor, including its physical location on macOS aliases.
    omz, custom = home_path(omz), home_path(custom)
    nodes = {}
    _zdx_install_inspect(home, nodes, directory=True, own=True)
    _zdx_install_inspect(source, nodes, directory=True)
    _zdx_install_inspect(omz, nodes, directory=True)
    _zdx_install_read(os.path.join(omz, "oh-my-zsh.sh"), nodes)
    hashes = {}
    for relative in ("scripts/install.sh", "scripts/install.zsh", "scripts/install_fs.py",
                     "functions.zsh", "zdx-suite.plugin.zsh", ".config/zdx/config.zsh.example"):
        path = os.path.join(source, relative)
        hashes[path] = hashlib.sha256(_zdx_install_read(path, nodes)).hexdigest()
    target = os.path.join(custom, "plugins", "zdx-suite")
    parent = os.path.dirname(target)
    _zdx_install_inspect(parent, nodes, optional=True, directory=True)
    target_info = os.lstat(target) if os.path.lexists(target) else None
    if target_info is None:
        nodes[target] = None
        link_needed = True
    elif stat.S_ISLNK(target_info.st_mode):
        linked = os.path.normpath(os.path.join(parent, os.readlink(target)))
        if target_info.st_uid != os.getuid() or linked != source:
            raise InstallError("plugin target is a different or untrusted symlink: " + target)
        nodes[target] = _zdx_install_identity(target_info)
        link_needed = False
    elif target == source and stat.S_ISDIR(target_info.st_mode):
        link_needed = False
    else:
        raise InstallError("plugin target already belongs to another path: " + target)
    config_dir = os.path.join(home, ".config", "zdx")
    config = os.path.join(config_dir, "config.zsh")
    _zdx_install_inspect(config_dir, nodes, optional=True, directory=True, own=True)
    config_info = _zdx_install_inspect(config, nodes, optional=True, private=True, own=True)
    if config_info is not None:
        hashes[config] = hashlib.sha256(_zdx_install_read(config, nodes, private=True, own=True)).hexdigest()
    plan = {"inputs": inputs, "source": source, "target": target, "config": config,
            "link_needed": link_needed, "config_needed": config_info is None,
            "nodes": nodes, "hashes": hashes}
    if announce:
        print("installer: validated local integration plan", file=sys.stderr)
        print("  Checkout: " + source, file=sys.stderr)
        print("  Plugin: " + ("create link " if link_needed else "preserve ") + target, file=sys.stderr)
        print("  Config: " + ("create private file " if config_info is None else "preserve ") + config, file=sys.stderr)
        print("  Missing parent directories will be created with mode 700; shell profiles remain for manual activation.", file=sys.stderr)
    return plan


def _zdx_install_open_dir(path, plan, created):
    """Pin validated directories; create missing components without replacing names."""
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    current = "/"
    try:
        for part in path.strip("/").split("/"):
            if not part:
                continue
            current = os.path.join(current, part)
            made = False
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            except FileNotFoundError:
                os.mkdir(part, 0o700, dir_fd=descriptor)
                created.append(current)
                made = True
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            info = os.fstat(child)
            _zdx_install_safe(info, current, directory=True)
            if made:
                os.fchmod(child, 0o700)
                info = os.fstat(child)
            expected = plan["nodes"].get(current)
            changed = expected is not None and _zdx_install_identity(info) != expected
            appeared = expected is None and not made and current not in created
            if changed or appeared:
                os.close(child)
                raise InstallError("directory changed before publication: " + current)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _zdx_install_revalidate(plan, created):
    for path, identity in plan["nodes"].items():
        if identity is None:
            if path not in created and os.path.lexists(path):
                raise InstallError("path appeared before publication: " + path)
        elif _zdx_install_identity(os.lstat(path)) != identity:
            raise InstallError("path changed before publication: " + path)
    for path, digest in plan["hashes"].items():
        private = path == plan["config"]
        data = _zdx_install_read(path, {}, private=private, own=private)
        if hashlib.sha256(data).hexdigest() != digest:
            raise InstallError("file changed before publication: " + path)


def _zdx_install_apply(plan):
    fresh = _zdx_install_plan(plan["inputs"])
    if fresh != plan:
        raise InstallError("installation paths or source changed; review a new --dry-run")
    # Only this short-lived helper's mask changes; preserve the invoking shell.
    os.umask(0o077)
    created = []
    published = []
    config_fd = None
    staging = None
    staging_identity = None
    try:
        # Pin both publication parents before publishing either final object.
        target_fd = _zdx_install_open_dir(os.path.dirname(plan["target"]), plan, created)
        try:
            config_fd = _zdx_install_open_dir(os.path.dirname(plan["config"]), plan, created)
            template = os.path.join(plan["source"], ".config/zdx/config.zsh.example")
            data = _zdx_install_read(template, {})
            _zdx_install_revalidate(plan, created)
            for path, descriptor in ((os.path.dirname(plan["target"]), target_fd),
                                     (os.path.dirname(plan["config"]), config_fd)):
                if _zdx_install_identity(os.lstat(path)) != _zdx_install_identity(os.fstat(descriptor)):
                    raise InstallError("publication parent moved: " + path)
            if hashlib.sha256(data).hexdigest() != plan["hashes"][template]:
                raise InstallError("configuration template changed before publication")
            if plan["config_needed"]:
                staging = ".zdx-install-" + secrets.token_hex(16)
                descriptor = os.open(staging, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                     0o600, dir_fd=config_fd)
                os.fchmod(descriptor, 0o600)
                staging_identity = _zdx_install_identity(os.fstat(descriptor))
                with os.fdopen(descriptor, "w+b") as stream:
                    stream.write(data)
                    stream.flush()
                    os.fsync(stream.fileno())
                    stream.seek(0)
                    named = os.stat(staging, dir_fd=config_fd, follow_symlinks=False)
                    if (_zdx_install_identity(named) != staging_identity
                            or _zdx_install_identity(os.fstat(stream.fileno())) != staging_identity
                            or hashlib.sha256(stream.read()).hexdigest() != plan["hashes"][template]):
                        raise InstallError("configuration staging changed before publication")
                    os.link(staging, "config.zsh", src_dir_fd=config_fd, dst_dir_fd=config_fd, follow_symlinks=False)
                published.append(plan["config"])
            if plan["link_needed"]:
                os.symlink(plan["source"], "zdx-suite", dir_fd=target_fd)
                published.append(plan["target"])
        finally:
            os.close(target_fd)
    except BaseException:
        if published or created:
            print("installer: interrupted or failed after creating these paths; review them and retry:", file=sys.stderr)
            for path in created + published:
                print("  " + path, file=sys.stderr)
        raise
    finally:
        if config_fd is not None:
            pending_error = sys.exc_info()[1]
            try:
                if staging is not None and staging_identity is not None:
                    info = os.stat(staging, dir_fd=config_fd, follow_symlinks=False)
                    # Publishing adds one hard link; all other identity fields must match.
                    if _zdx_install_identity(info)[:4] == staging_identity[:4]:
                        os.unlink(staging, dir_fd=config_fd)
                    else:
                        raise InstallError("staging identity changed")
            except FileNotFoundError:
                pass
            except (OSError, InstallError) as error:
                retained = os.path.join(os.path.dirname(plan["config"]), staging)
                messages = ("private staging cleanup failed: " + str(error),
                            "retained " + retained + "; review it and " + plan["config"]
                            + " before retrying; a published config may still have two hard links.")
                if pending_error is None:
                    raise InstallError("; ".join(messages))
                for message in messages:
                    print("installer: " + message, file=sys.stderr)
            finally:
                os.close(config_fd)


def _zdx_install_main():
    def interrupted(signum, _frame):
        raise KeyboardInterrupt(signum)
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    try:
        if sys.version_info < (3, 8):
            raise InstallError("Python 3.8 or newer is required")
        if len(sys.argv) == 7 and sys.argv[1] == "plan":
            print(json.dumps(_zdx_install_plan(sys.argv[2:], announce=True), sort_keys=True))
        elif sys.argv[1:] == ["apply"]:
            _zdx_install_apply(json.load(sys.stdin))
        else:
            raise InstallError("private installer helper: invalid invocation")
        return 0
    except KeyboardInterrupt as error:
        signum = error.args[0] if error.args else signal.SIGINT
        print("installer: interrupted; integration was not declared complete.", file=sys.stderr)
        return 130 if signum == signal.SIGINT else 143
    except (InstallError, OSError, ValueError, KeyError) as error:
        print("installer: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(_zdx_install_main())
