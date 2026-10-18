"""Drive the installer ISO and the installed system over QEMU's serial console.

Each mode exits non-zero on the first failed check. Logs go to OUT_DIR.

  drive.py install OUT_DIR ISO DISK
  drive.py service OUT_DIR DISK TRUTHDB_CLI
  drive.py login   OUT_DIR DISK KERNEL INITRD CMDLINE
"""

import os
import re
import subprocess
import sys
import threading
import time

PASSWORD = "Adm1n-e2e-pw"
OVMF_CODE = "/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS = "/usr/share/OVMF/OVMF_VARS_4M.fd"
KVM = os.access("/dev/kvm", os.R_OK | os.W_OK)
# Software emulation is several times slower than KVM.
SLOW = 1 if KVM else 6


def fail(message):
    raise SystemExit(f"FAIL: {message}")


class Vm:
    def __init__(self, args, log_path):
        self.log_path = log_path
        self.log = open(log_path, "w", buffering=1)
        self.buf = ""
        self.lock = threading.Lock()
        self.proc = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while True:
            chunk = self.proc.stdout.read1(4096)
            if not chunk:
                return
            text = chunk.decode("utf-8", "replace")
            self.log.write(text)
            with self.lock:
                self.buf += text

    def wait_for(self, pattern, timeout):
        """Wait until `pattern` appears in unconsumed output; consume up to the match."""
        deadline = time.time() + timeout * SLOW
        while time.time() < deadline:
            with self.lock:
                m = re.search(pattern, self.buf)
                if m:
                    self.buf = self.buf[m.end():]
                    return m
            if self.proc.poll() is not None:
                fail(f"qemu exited while waiting for {pattern!r} (see {self.log_path})")
            time.sleep(0.2)
        self.stop()
        fail(f"timeout waiting for {pattern!r} (see {self.log_path})")

    def send(self, text, delay=0.05):
        for ch in text:
            self.proc.stdin.write(ch.encode())
            self.proc.stdin.flush()
            time.sleep(delay)

    def stop(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait()


def qemu(out_dir, disk, net="user,model=virtio-net-pci"):
    accel = ["-machine", "q35,accel=kvm", "-cpu", "host"] if KVM else [
        "-machine", "q35,accel=tcg", "-cpu", "max"]
    return ["qemu-system-x86_64", *accel,
            "-m", "2048", "-smp", "2", "-display", "none", "-serial", "stdio",
            "-monitor", "none", "-no-reboot",
            "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
            "-drive", f"if=pflash,format=raw,file={out_dir}/vars.fd",
            "-drive", f"file={disk},if=virtio,format=qcow2",
            "-nic", net]


def install(out_dir, iso, disk):
    print(f"acceleration: {'kvm' if KVM else 'tcg'}")
    subprocess.run(["cp", OVMF_VARS, f"{out_dir}/vars.fd"], check=True)
    vm = Vm(qemu(out_dir, disk) + ["-cdrom", iso, "-boot", "d"], f"{out_dir}/install.log")
    vm.wait_for(r"Install TruthDB \(serial console\)", 180)
    time.sleep(1)
    for _ in range(4):  # the fifth GRUB entry
        vm.send("\x1b[B")
        time.sleep(0.3)
    vm.send("\r")

    # A mismatched pair must be rejected and asked again.
    vm.wait_for(r"Password for the admin account", 300)
    vm.send("first-try\r")
    vm.wait_for(r"Repeat the password", 30)
    vm.send("second-try\r")
    vm.wait_for(r"The passwords do not match", 30)
    vm.wait_for(r"Password for the admin account", 30)
    vm.send(PASSWORD + "\r")
    vm.wait_for(r"Repeat the password", 30)
    vm.send(PASSWORD + "\r")
    vm.wait_for(r"Press ENTER to continue", 30)
    vm.send("\r")
    m = vm.wait_for(r"\[OK\] Install complete|\[ERR\] Installer encountered an error", 900)
    if "ERR" in m.group(0):
        vm.stop()
        fail(f"installer reported an error (see {vm.log_path})")
    vm.wait_for(r"Press ENTER to reboot", 60)
    vm.send("\r")
    vm.proc.wait(timeout=120 * SLOW)

    log = open(vm.log_path, encoding="utf-8", errors="replace").read()
    for secret in ("first-try", "second-try", PASSWORD):
        if secret in log:
            fail(f"{secret!r} was echoed on the console")
    errors = [l for l in log.splitlines() if "[ERR]" in l and "do not match" not in l]
    if errors:
        fail("installer errors:\n" + "\n".join(errors))
    print("install: ok (mismatch re-prompted, nothing echoed, every step [OK])")


def service(out_dir, disk, cli):
    vm = Vm(qemu(out_dir, disk,
                 net="user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:19623-:9623"),
            f"{out_dir}/service.log")
    deadline = time.time() + 300 * SLOW
    out = ""
    while time.time() < deadline:
        r = subprocess.run([cli, "--host", "127.0.0.1", "--port", "19623", "repl"],
                           input=b"SELECT 40 + 2 AS answer;\n", capture_output=True,
                           timeout=60)
        out = r.stdout.decode(errors="replace") + r.stderr.decode(errors="replace")
        if re.search(r"^\s*42\s*$", out, re.M):
            break
        time.sleep(5)
    vm.stop()
    if not re.search(r"^\s*42\s*$", out, re.M):
        fail(f"no answer 42 over the native protocol on port 9623:\n{out}")
    print("service: ok (SELECT 40 + 2 returned 42 through port 9623)")


def login(out_dir, disk, kernel, initrd, cmdline):
    vm = Vm(qemu(out_dir, disk) + ["-kernel", kernel, "-initrd", initrd,
                                   "-append", cmdline + " console=ttyS0,115200"],
            f"{out_dir}/login.log")
    vm.wait_for(r"login: ", 240)
    vm.send("root\r")
    vm.wait_for(r"Password: ", 30)
    vm.send(PASSWORD + "\r")
    vm.wait_for(r"Login incorrect", 60)
    vm.wait_for(r"login: ", 60)
    vm.send("admin\r")
    vm.wait_for(r"Password: ", 30)
    vm.send(PASSWORD + "\r")
    vm.wait_for(r"\$ ", 60)
    # Each check prints one tagged line; the tags are matched below.
    checks = [
        f"echo '{PASSWORD}' | sudo -S -v 2>/dev/null && echo CHK sudo=ok",
        "echo CHK root=$(sudo -n passwd -S root | cut -d' ' -f2)",
        "echo CHK truthdb=$(getent passwd truthdb | cut -d: -f6,7)",
        "echo CHK active=$(systemctl is-active truthdb)",
        "echo CHK user=$(systemctl show -p User --value truthdb)",
        "echo CHK exec=$(systemctl show -p ExecStart --value truthdb | sed 's/.*path=\\([^ ;]*\\).*/\\1/')",
        "echo CHK done",
    ]
    for cmd in checks:
        vm.send(cmd + "\r", delay=0.01)
        time.sleep(1)
    vm.wait_for(r"CHK done", 60 * SLOW)
    vm.send("sudo -n poweroff\r", delay=0.01)
    try:
        vm.proc.wait(timeout=120 * SLOW)
    except subprocess.TimeoutExpired:
        vm.stop()

    log = open(vm.log_path, encoding="utf-8", errors="replace").read()
    seen = dict(re.findall(r"^CHK (\w+)=(.*?)\r?$", log, re.M))
    expected = {
        "sudo": "ok",
        "root": "L",
        "truthdb": "/var/lib/truthdb:/usr/sbin/nologin",
        "active": "active",
        "user": "truthdb",
        "exec": "/usr/bin/truthdb",
    }
    wrong = {k: (v, seen.get(k)) for k, v in expected.items() if seen.get(k) != v}
    if wrong:
        fail("login checks (expected, got): " + repr(wrong))
    print("login: ok (root locked, admin + sudo work, truthdb runs as a no-login system user)")


if __name__ == "__main__":
    mode, out = sys.argv[1], sys.argv[2]
    if mode == "install":
        install(out, *sys.argv[3:5])
    elif mode == "service":
        service(out, *sys.argv[3:5])
    elif mode == "login":
        login(out, *sys.argv[3:7])
    else:
        fail(f"unknown mode {mode}")
